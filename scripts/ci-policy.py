#!/usr/bin/env python3
"""Repository-local CI selection and fail-closed result evaluation (stdlib only)."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

JOBS = ("policy", "core", "documentation", "docc", "platforms", "coverage",
        "sanitizers", "performance", "migration", "remote-consumer")
SHA = re.compile(r"[0-9a-f]{40}")
PR_ACTIONS = {"opened", "synchronize", "reopened", "edited", "labeled", "unlabeled"}
WORKFLOW_IMPACT = {
    "ci.yml": set(JOBS),
    "principle-gates.yml": {"core", "documentation", "docc"},
    "docs-ci.yml": {"docc"},
    "platforms.yml": {"platforms"},
    "coverage.yml": {"coverage"},
    "sanitizers.yml": {"sanitizers"},
    "performance-smoke.yml": {"performance"},
    "migration-smoke.yml": {"migration"},
    "release.yml": set(JOBS),
    "dependabot-auto-merge.yml": set(),
    "dependabot-review-notice.yml": set(),
}


def path_impact(path):
    if not isinstance(path, str) or not path or "\x00" in path or "\n" in path:
        raise ValueError("invalid changed path")
    if path.startswith("/") or any(p in ("..", ".", "") for p in path.split("/")) or "\\" in path:
        raise ValueError("changed path must be a repository-relative POSIX path")
    if path in ("Package.swift", "Package.resolved") or path.startswith(".github/actions/"):
        return set(JOBS), "shared package/toolchain"
    if path.startswith(".github/workflows/"):
        name = path.rsplit("/", 1)[1]
        if name in WORKFLOW_IMPACT:
            return WORKFLOW_IMPACT[name], "workflow:" + name
    if path == ".spi.yml" or ".docc/" in path or path == "scripts/build-docc-site.sh":
        return {"documentation", "docc"}, "DocC/SPI"
    if path.startswith(("Sources/", "Plugins/", "Tests/", "Examples/", "ExamplesSmoke/")):
        # Router runtime/SwiftUI/macro and their tests/examples have cross-platform,
        # native scene, restoration and instrumentation effects. Preserve every
        # existing protected gate; only the earlier explicit DocC scope narrows it.
        return set(JOBS), "source/macro/test/example (all Router gates)"
    if path.startswith(("ConsumerSmoke/", "NativeSceneSmoke/")):
        return {"core", "platforms", "remote-consumer"}, "consumer/native scene"
    if path.startswith("MigrationSmoke/"):
        return {"migration"}, "historical migration contract"
    if path.startswith(("scripts/tests/", ".github/ISSUE_TEMPLATE/")) or path in (
            ".github/dependabot.yml", ".github/PULL_REQUEST_TEMPLATE.md", "LICENSE", "SECURITY.md"):
        return set(), "public operations"
    if path.startswith("scripts/check-doc") or path == "scripts/test-check-doc-metadata.py":
        return {"documentation"}, "documentation checker"
    if path.startswith("scripts/"):
        return set(JOBS), "shared CI/build/release script"
    if path.endswith(".md") or path.startswith("Docs/"):
        return {"documentation"}, "documentation"
    return set(JOBS), "unknown path (full fallback)"


def changed_paths(root, base, head):
    if not SHA.fullmatch(base or "") or not SHA.fullmatch(head or ""):
        raise ValueError("diff anchors must be exact lowercase commit SHAs")
    raw = subprocess.check_output(["git", "-C", str(root), "diff", "--name-status", "-z",
                                   "--find-renames", base + "..." + head])
    tokens = raw.decode("utf-8", errors="strict").split("\x00")
    if tokens[-1] != "":
        raise ValueError("truncated Git changed-file stream")
    tokens.pop()
    paths = []
    while tokens:
        status = tokens.pop(0)
        if not re.fullmatch(r"[ACDMRTUXB][0-9]*", status):
            raise ValueError("unknown Git file status")
        count = 2 if status[0] in "RC" else 1
        if len(tokens) < count:
            raise ValueError("missing changed-file path")
        # Renames/copies must include BOTH old and new paths; deleted files
        # remain in the impact set even though they no longer exist on disk.
        paths.extend(tokens[:count])
        del tokens[:count]
    return paths


def make_plan(event_name, event, paths):
    if not isinstance(event, dict) or not isinstance(paths, list):
        raise ValueError("event and changed paths have invalid types")
    lane = "full"
    if event_name == "pull_request":
        pr = event.get("pull_request", {})
        if event.get("action") not in PR_ACTIONS or not isinstance(pr, dict):
            raise ValueError("unsupported PR event")
        if event["action"] == "edited" and not event.get("changes", {}).get("base"):
            raise ValueError("metadata-only edit must not create a validation plan")
        labels = pr.get("labels")
        if not isinstance(labels, list) or any(not isinstance(x, dict) or not isinstance(x.get("name"), str) for x in labels):
            raise ValueError("missing or malformed PR labels")
        author = pr.get("user", {}).get("login")
        lane = "release-validation" if author == "dependabot[bot]" or any(x["name"].lower() == "release-validation" for x in labels) else "fast"
    elif event_name == "push":
        if event.get("ref") not in ("refs/heads/main", "refs/heads/develop"):
            raise ValueError("CI push must target main/develop")
    elif event_name == "merge_group":
        if event.get("action") != "checks_requested":
            raise ValueError("unsupported merge queue event")
    elif event_name != "workflow_dispatch":
        raise ValueError("unsupported CI event")
    selected = {"policy"}
    reasons = []
    for path in paths:
        impact, reason = path_impact(path)
        selected.update(impact)
        reasons.append({"path": path, "reason": reason})
    # An empty/missing diff is never evidence that no verification is needed.
    if lane != "fast" or not paths:
        selected = set(JOBS)
    return {"schema": 1, "lane": lane, "jobs": {j: j in selected for j in JOBS},
            "changes": reasons}


def validate_plan(plan):
    if not isinstance(plan, dict) or set(plan) != {"schema", "lane", "jobs", "changes"}:
        raise ValueError("missing or unknown plan fields")
    if type(plan["schema"]) is not int or plan["schema"] != 1 or plan["lane"] not in ("fast", "full", "release-validation"):
        raise ValueError("unsupported plan schema/lane")
    if not isinstance(plan["jobs"], dict) or set(plan["jobs"]) != set(JOBS) or any(type(v) is not bool for v in plan["jobs"].values()):
        raise ValueError("plan must declare every job with a boolean")
    if plan["jobs"]["policy"] is not True:
        raise ValueError("policy must always run")
    if not isinstance(plan["changes"], list):
        raise ValueError("invalid change evidence")
    if plan["lane"] != "fast" and not all(plan["jobs"].values()):
        raise ValueError("full lanes cannot opt out of required jobs")
    if not plan["changes"] and not all(plan["jobs"].values()):
        raise ValueError("empty change evidence requires full validation")
    for change in plan["changes"]:
        if not isinstance(change, dict) or set(change) != {"path", "reason"}:
            raise ValueError("invalid change record")
        impact, reason = path_impact(change["path"])
        if change["reason"] != reason or any(not plan["jobs"][j] for j in impact):
            raise ValueError("plan suppresses changed-path requirements")


def evaluate(plan, needs):
    validate_plan(plan)
    if not isinstance(needs, dict) or set(needs) != set(JOBS) | {"ci-plan"}:
        raise ValueError("missing or unexpected CI result")
    required = {"ci-plan": True, **plan["jobs"]}
    for job, selected in required.items():
        result = needs[job].get("result") if isinstance(needs[job], dict) else None
        expected = "success" if selected else "skipped"
        if result != expected:
            raise ValueError(f"{job}: expected {expected}, got {result!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan_cmd = sub.add_parser("plan")
    plan_cmd.add_argument("--event", required=True, type=Path)
    plan_cmd.add_argument("--root", type=Path, default=Path("."))
    plan_cmd.add_argument("--output", type=Path, required=True)
    evaluate_cmd = sub.add_parser("evaluate")
    evaluate_cmd.add_argument("--plan-json", default=os.environ.get("CI_PLAN", ""))
    evaluate_cmd.add_argument("--needs-json", default=os.environ.get("CI_NEEDS", ""))
    strict_cmd = sub.add_parser("require")
    strict_cmd.add_argument("--jobs", nargs="+", required=True)
    strict_cmd.add_argument("--skipped", nargs="*", default=[])
    strict_cmd.add_argument("--needs-json", default=os.environ.get("CI_NEEDS", ""))
    args = parser.parse_args()
    try:
        if args.command == "plan":
            event = json.loads(args.event.read_text())
            event_name = os.environ["GITHUB_EVENT_NAME"]
            paths = []
            if event_name == "pull_request":
                pr = event["pull_request"]
                paths = changed_paths(args.root, pr["base"]["sha"], pr["head"]["sha"])
            plan = make_plan(event_name, event, paths)
            validate_plan(plan)
            payload = json.dumps(plan, separators=(",", ":"))
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(payload + "\n")
            if "GITHUB_OUTPUT" in os.environ:
                with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                    stream.write("plan=" + payload + "\n")
                    for job, selected in plan["jobs"].items():
                        stream.write(job + "=" + str(selected).lower() + "\n")
            print(json.dumps(plan, indent=2))
        elif args.command == "evaluate":
            evaluate(json.loads(args.plan_json), json.loads(args.needs_json))
            print("CI Required: every planned job succeeded; only declared non-targets skipped.")
        else:
            needs = json.loads(args.needs_json)
            all_jobs = args.jobs + args.skipped
            if len(set(all_jobs)) != len(all_jobs) or set(needs) != set(all_jobs):
                raise ValueError("missing or unexpected required result")
            for job in args.jobs:
                if not isinstance(needs[job], dict) or needs[job].get("result") != "success":
                    raise ValueError(f"{job}: required result is not success")
            for job in args.skipped:
                if not isinstance(needs[job], dict) or needs[job].get("result") != "skipped":
                    raise ValueError(f"{job}: non-target result must be skipped")
            print("All required validation jobs succeeded.")
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"CI policy rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
