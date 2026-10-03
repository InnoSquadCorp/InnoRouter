#!/usr/bin/env python3
"""Trusted metadata-only Dependabot coordinator. Never downloads PR code/artifacts."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "InnoSquadCorp/InnoRouter"
CI_PATH = ".github/workflows/ci.yml"
NOTICE_PATH = ".github/workflows/dependabot-review-notice.yml"
READY = "Dependabot Merge Ready"
APP = 15368
BOT = {"login": "dependabot[bot]", "id": 49699333, "type": "Bot"}
SHA = re.compile(r"[0-9a-f]{40}")
PREFIX = "CI / Dependabot merge #"
# All bot updates, including major/toolchain updates, need the full contract.
# The native required ready check is separate from these inputs (no cycle).
import router_ci_adapter


class Rejected(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


class GitHub:
    def __init__(self, token=None):
        self.token = token or os.environ.get("GH_TOKEN")
        require(bool(self.token), "missing job token")

    def request(self, method, path, payload=None):
        require(path == "graphql" or path == f"repos/{REPOSITORY}" or path.startswith(f"repos/{REPOSITORY}/"), "foreign API target")
        request = urllib.request.Request("https://api.github.com/" + path,
            data=None if payload is None else json.dumps(payload).encode(), method=method,
            headers={"Authorization": "Bearer " + self.token,
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2022-11-28"})
        # No mutation retries: an unknown outcome must be read back first.
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return (json.loads(raw) if raw else None), response.headers

    def get(self, path):
        return self.request("GET", path)[0]

    def mutate(self, method, path, payload):
        return self.request(method, path, payload)[0]

    def pages(self, path, key=None):
        result = []
        page = 1
        while True:
            separator = "&" if "?" in path else "?"
            data, headers = self.request("GET", f"{path}{separator}per_page=100&page={page}")
            values = data if key is None else data.get(key)
            require(isinstance(values, list), "malformed paginated API result")
            result.extend(values)
            if 'rel="next"' not in headers.get("Link", ""):
                if key and "total_count" in data:
                    require(len(result) == data["total_count"], "truncated API pages")
                return result
            page += 1
            require(page <= 100, "excessive API pagination")

    def graphql(self, query, variables):
        response = self.mutate("POST", "graphql", {"query": query, "variables": variables})
        require(isinstance(response, dict) and not response.get("errors") and isinstance(response.get("data"), dict),
                "GraphQL returned errors or missing data")
        return response["data"]


def route(suffix):
    return f"repos/{REPOSITORY}" + ("/" + suffix if suffix else "")


def trusted_context(environment):
    require(environment.get("GITHUB_REPOSITORY") == REPOSITORY and
            environment.get("GITHUB_REF") == "refs/heads/main" and
            environment.get("GITHUB_WORKFLOW_REF") == REPOSITORY + "/.github/workflows/dependabot-auto-merge.yml@refs/heads/main",
            "mutation requires trusted default-main workflow/ref")


def bot(pr):
    return all(pr.get("user", {}).get(k) == v for k, v in BOT.items())


def basic(pr, repo, require_open=True):
    require(pr.get("base", {}).get("ref") == "main", "wrong base branch")
    require(pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY, "wrong target repository")
    require(pr.get("head", {}).get("repo", {}).get("id") == repo["id"] and
            pr["head"]["repo"].get("full_name") == REPOSITORY, "fork or missing head repository")
    require(bool(SHA.fullmatch(pr.get("head", {}).get("sha", ""))), "invalid head SHA")
    require(bot(pr), "PR author is not verified Dependabot")
    if require_open:
        require(pr.get("state") == "open" and pr.get("merged") is False, "PR not open")
        require(pr.get("draft") is False, "draft PR")
        require(pr.get("mergeable") is True, "conflict or unknown mergeability")


def native_rules(api, repo):
    require(repo.get("allow_auto_merge") is True and repo.get("allow_squash_merge") is True,
            "native auto-merge/squash feature disabled")
    rules = api.pages(route("rules/branches/main"))
    status = [r for r in rules if r.get("type") == "required_status_checks"]
    require(bool(status), "native required checks absent")
    contexts = set()
    for rule in status:
        parameters = rule.get("parameters", {})
        require(parameters.get("strict_required_status_checks_policy") is True, "loose native CI policy")
        for check in parameters.get("required_status_checks", []):
            require(check.get("integration_id") == APP, "required check has wrong app or any source")
            contexts.add(check.get("context"))
        source = rule.get("ruleset_source")
        require(rule.get("ruleset_source_type") == "Repository" and source == REPOSITORY,
                "unverified inherited protection")
        ruleset = api.get(route(f"rulesets/{rule['ruleset_id']}"))
        require(ruleset.get("enforcement") == "active", "inactive protection")
        # Bypass actors are redacted without Administration write. Activation
        # verifies the app has no bypass once; never interpret a missing list as
        # empty or add an admin credential just to audit unrelated actors.
        if "current_user_can_bypass" in ruleset:
            require(ruleset["current_user_can_bypass"] == "never", "coordinator token can bypass protection")
        if "bypass_actors" in ruleset:
            require(not any(a.get("actor_type") == "Integration" and a.get("actor_id") == APP
                            for a in ruleset["bypass_actors"]), "GitHub Actions has protection bypass")
    require({"CI Required", READY} <= contexts, "native CI/ready requirement missing")


def reviews(api, number):
    latest = {}
    for review in sorted(api.pages(route(f"pulls/{number}/reviews")), key=lambda r: r["id"]):
        state = review.get("state")
        require(state in {"APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"}, "unknown review state")
        if state != "COMMENTED":
            latest[review["user"]["id"]] = state
    require(not any(s in {"CHANGES_REQUESTED", "PENDING"} for s in latest.values()), "review blocks auto-merge")
    cursor = None
    while True:
        data = api.graphql('''query($number:Int!,$cursor:String) {
          repository(owner:"InnoSquadCorp",name:"InnoRouter") { pullRequest(number:$number) {
            id headRefOid reviewDecision reviewThreads(first:100,after:$cursor) {
              nodes { isResolved } pageInfo { hasNextPage endCursor }
            }
          } }
        }''', {"number": number, "cursor": cursor})["repository"]["pullRequest"]
        require(data is not None and data.get("reviewDecision") not in {"CHANGES_REQUESTED", "REVIEW_REQUIRED"}, "native review decision blocks")
        threads = data["reviewThreads"]
        require(all(t.get("isResolved") is True for t in threads["nodes"]), "unresolved review thread")
        if not threads["pageInfo"]["hasNextPage"]:
            return data
        next_cursor = threads["pageInfo"]["endCursor"]
        require(isinstance(next_cursor, str) and next_cursor and next_cursor != cursor, "invalid review pagination")
        cursor = next_cursor


def proof(api, number, notification=None):
    repo = api.get(route(""))
    require(repo.get("full_name") == REPOSITORY and repo.get("default_branch") == "main", "wrong repository/default branch")
    pr = api.get(route(f"pulls/{number}"))
    if pr.get("mergeable") is None:  # One bounded read retry; never retry writes.
        pr = api.get(route(f"pulls/{number}"))
    basic(pr, repo)
    native_rules(api, repo)
    main = api.get(route("git/ref/heads/main"))["object"]["sha"]
    require(pr["base"]["sha"] == main, "base is no longer main")
    head = pr["head"]["sha"]
    merge_sha = pr.get("merge_commit_sha")
    require(bool(SHA.fullmatch(merge_sha or "")), "missing test-merge SHA")
    parents = api.get(route(f"git/commits/{merge_sha}"))["parents"]
    require([p["sha"] for p in parents] == [main, head], "test-merge parents do not match base/head")
    graph = reviews(api, number)
    require(graph["headRefOid"] == head, "head raced during reviews")
    require(not pr.get("requested_reviewers") and not pr.get("requested_teams"), "review request pending")
    evidence = router_ci_adapter.verify(api, REPOSITORY, pr, repo, notification, require)
    return {"pr": pr, "node": graph["id"], "head": head, "base": main, "merge": merge_sha, **evidence}


def same(left, right):
    require(all(left[k] == right[k] for k in ("head", "base", "merge", "run", "attempt", "node", "evidence")), "head/base/CI attempt raced")


def gate(api, number, head, status, check_id=None, reason="Metadata verification"):
    payload = {"name": READY, "head_sha": head, "status": status,
               "external_id": f"dependabot-policy:{number}:{head}",
               "output": {"title": READY, "summary": reason}}
    if status == "completed":
        payload["conclusion"] = "success"
    if status == "failure":
        payload.update(status="completed", conclusion="failure")
    if check_id is None:
        existing = [c for c in api.pages(route(f"commits/{head}/check-runs?filter=all"), "check_runs")
                    if c.get("name") == READY and c.get("app", {}).get("id") == APP and
                    c.get("external_id") == payload["external_id"] and c.get("head_sha") == head]
        require(len(existing) <= 1, "duplicate managed ready checks")
        if not existing:
            try:
                observed = api.mutate("POST", route("check-runs"), payload)
            except Exception:
                matches = [c for c in api.pages(route(f"commits/{head}/check-runs?filter=all"), "check_runs")
                           if c.get("external_id") == payload["external_id"] and c.get("name") == READY]
                require(len(matches) == 1, "ready creation outcome unconfirmed; no retry")
                observed = matches[0]
            check_id = observed["id"]
            require(observed.get("app", {}).get("id") == APP and observed.get("status") == payload["status"] and
                    observed.get("head_sha") == head and observed.get("external_id") == payload["external_id"] and
                    ("conclusion" not in payload or observed.get("conclusion") == payload["conclusion"]), "ready creation not confirmed")
            return check_id
        check_id = existing[0]["id"]
    payload.pop("head_sha")
    try:
        observed = api.mutate("PATCH", route(f"check-runs/{check_id}"), payload)
    except Exception:
        observed = api.get(route(f"check-runs/{check_id}"))
    require(observed.get("app", {}).get("id") == APP and observed.get("status") == payload["status"] and
            observed.get("external_id") == payload["external_id"] and observed.get("head_sha") == head and
            ("conclusion" not in payload or observed.get("conclusion") == payload["conclusion"]), "ready update not confirmed")
    return check_id


def coordinate(api, number, enabled=False, notification=None):
    pr = api.get(route(f"pulls/{number}"))
    require(pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY, "foreign target")
    if pr.get("state") != "open":
        return "closed: reconcile post-merge separately"
    head = pr.get("head", {}).get("sha", "")
    require(bool(SHA.fullmatch(head)), "invalid gate head")
    if pr["base"].get("ref") != "main":
        if bot(pr):
            try:
                gate(api, number, head, "failure", reason="Base changed: only protected main is eligible.")
            finally:
                cancel_auto_merge(api, pr)
        return "wrong base: auto-merge ineligible"
    if not bot(pr):
        gate(api, number, head, "completed", reason="Manual PR: automation ineligible; normal CI/review requirements remain.")
        return "manual PR; auto-merge not requested"
    check_id = None
    try:
        # Notifications are only wake-ups. Obsolete run events do not overwrite a
        # newer decision; current pending/failure events invalidate readiness.
        if notification:
            current = api.get(route(f"actions/runs/{notification['id']}"))
            if current.get("run_attempt") != notification.get("run_attempt") or current.get("head_sha") != head:
                return "obsolete notification; no mutation"
            runs = api.pages(route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
            workflow = api.get(route('actions/workflows/ci.yml'))
            repo = api.get(route(''))
            runs, _, metadata = router_ci_adapter.validation_runs(api, runs, workflow['id'], repo['id'], number,
                                                                  head, pr['merge_commit_sha'], require)
            if (notification['id'], notification['run_attempt']) in metadata:
                notification = None
            elif not runs or max(runs, key=lambda r: (r['run_number'], r['id']))['id'] != notification['id']:
                return 'obsolete notification; no mutation'

        check_id = gate(api, number, head, "in_progress", reason="Awaiting verified full CI and current metadata.")
        require(enabled is True, "standby: new auto-merge approvals disabled")
        first = proof(api, number, notification)
        require(first["head"] == head, "head changed before native enable")
        second = proof(api, number, notification)
        same(first, second)
        if not second["pr"].get("auto_merge"):
            query = '''mutation($id:ID!,$head:GitObjectID!) {
              enablePullRequestAutoMerge(input:{pullRequestId:$id,expectedHeadOid:$head,mergeMethod:SQUASH}) {
                pullRequest { id headRefOid autoMergeRequest { enabledAt } }
              }
            }'''
            try:
                api.graphql(query, {"id": second["node"], "head": head})
            except Exception:
                # Unknown mutation outcome: read once, never blind retry/fallback.
                observed = api.get(route(f"pulls/{number}"))
                require(observed.get("head", {}).get("sha") == head and observed.get("auto_merge") is not None,
                        "native enable outcome not confirmed")
        third = proof(api, number, notification)
        same(second, third)
        gate(api, number, head, "completed", check_id, "Verified full CI, exact head/base and latest attempt; native strict requirements apply.")
        return "native auto-merge armed; server owns actual merge"
    except Exception as error:
        reason = "blocked: " + str(error)
        try:
            # An unconfirmed initial POST/PATCH must not lead to a second
            # creation. Cancel independently and let a later read reconcile it.
            if check_id is not None:
                gate(api, number, head, "failure", check_id, "Auto-merge rejected: " + str(error))
        except Exception as gate_error:
            reason += "; ready update unconfirmed: " + str(gate_error)
        finally:
            try:
                cancel_auto_merge(api, api.get(route(f"pulls/{number}")))
            except Exception as cancel_error:
                # No claim that a previously armed request was stopped when
                # both APIs are unavailable. Surface an operator-visible failure.
                raise Rejected(reason + "; cancellation unconfirmed: " + str(cancel_error)) from cancel_error
        return reason


def cancel_auto_merge(api, pr):
    # Protective cancellation is limited to verified bot PRs in this repository.
    # A failure never falls back to a direct merge or blind mutation retry.
    if bot(pr) and pr.get("auto_merge") and pr.get("state") == "open":
        require(pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY, "foreign cancellation")
        try:
            api.graphql('''mutation($id:ID!) {
              disablePullRequestAutoMerge(input:{pullRequestId:$id}) { pullRequest { id } }
            }''', {"id": pr["node_id"]})
        except Exception:
            observed = api.get(route(f"pulls/{pr['number']}"))
            require(not observed.get("auto_merge") or observed.get("state") == "closed", "native cancellation not confirmed")


def verify_post_merge(api, number, expected_sha):
    require(bool(SHA.fullmatch(expected_sha or "")), "invalid expected main SHA")
    repo = api.get(route(""))
    pr = api.get(route(f"pulls/{number}"))
    basic(pr, repo, require_open=False)
    require(pr.get("state") == "closed" and pr.get("merged") is True and
            pr.get("merge_commit_sha") == expected_sha, "not the actual merged Dependabot PR")
    require(api.get(route("git/ref/heads/main"))["object"]["sha"] == expected_sha, "stale main publication origin")
    return pr


def post_merge(api, enabled=False):
    if enabled is not True:
        return "standby: no post-merge dispatch"
    main = api.get(route("git/ref/heads/main"))["object"]["sha"]
    prs = api.pages(route(f"commits/{main}/pulls"))
    merged = [p for p in prs if bot(p) and p.get("merged_at") and p.get("merge_commit_sha") == main]
    if len(merged) != 1:
        return "no unique Dependabot merge at current main"
    number = merged[0]["number"]
    verify_post_merge(api, number, main)
    runs = api.pages(route(f"actions/workflows/ci.yml/runs?branch=main&head_sha={main}"), "workflow_runs")
    for run in runs:
        if run.get("head_sha") == main and (run.get("event") == "push" or
                (run.get("event") == "workflow_dispatch" and run.get("display_title") == PREFIX + str(number))):
            return "main CI already exists; no duplicate or failed-run retry"
    verify_post_merge(api, number, main)
    # Exact workflow/ref hardcoded. No arbitrary dispatch supplied by a PR.
    try:
        api.mutate("POST", route("actions/workflows/ci.yml/dispatches"),
                   {"ref": "main", "inputs": {"dependabot_merge_pr": str(number)}})
    except Exception:
        observed = api.pages(route(f"actions/workflows/ci.yml/runs?branch=main&head_sha={main}"), "workflow_runs")
        require(any(r.get("event") == "workflow_dispatch" and r.get("display_title") == PREFIX + str(number)
                    for r in observed), "dispatch outcome uncertain; no retry")
    return "verified current-main CI dispatched"


def targets(api, event_name, event):
    if event_name == "pull_request_target":
        return [event["pull_request"]["number"]], None
    if event_name == "workflow_run":
        alert = event["workflow_run"]
        live = api.get(route(f"actions/runs/{alert['id']}"))
        require(live.get("repository", {}).get("full_name") == REPOSITORY, "foreign notification")
        path = live.get("path", "").split("@")[0]
        require(path in {CI_PATH, NOTICE_PATH}, "unrecognized notification workflow")
        if path == CI_PATH and live.get("event") != "pull_request":
            return [], None
        require(live.get("event") in {"pull_request", "pull_request_review", "pull_request_review_comment"}, "wrong notification event")
        numbers = [p["number"] for p in live.get("pull_requests", [])]
        require(len(numbers) == 1, "missing/ambiguous notification PR")
        return numbers, alert if path == CI_PATH else None
    require(event_name in {"schedule", "workflow_dispatch", "push"}, "unsupported coordinator event")
    return [p["number"] for p in api.pages(route("pulls?state=open&base=main"))], None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("targets", "coordinate", "post-merge", "verify-post-merge"))
    parser.add_argument("--pr", type=int)
    parser.add_argument("--expected-sha")
    args = parser.parse_args()
    try:
        if args.command in {"coordinate", "verify-post-merge"}:
            require(type(args.pr) is int and args.pr > 0, "missing/invalid PR number")
        if args.command in {"coordinate", "post-merge"}:
            trusted_context(os.environ)
        api = GitHub()
        require(os.environ.get("GITHUB_REPOSITORY", REPOSITORY) == REPOSITORY, "foreign workflow repository")
        enabled = os.environ.get("DEPENDABOT_AUTO_MERGE_ENABLED") == "true"
        if args.command == "verify-post-merge":
            verify_post_merge(api, args.pr, args.expected_sha)
            print("Verified actual Dependabot merge at exact current main.")
            return 0
        if args.command == "post-merge":
            # Native completion may lag gate success; a bounded poll plus hourly
            # reconciliation handles token-suppressed push/closed events.
            for attempt in range(7):
                result = post_merge(api, enabled)
                if result != "no unique Dependabot merge at current main" or not enabled:
                    break
                if attempt < 6:
                    time.sleep(5)
            print(result)
            return 0
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        numbers, notification = targets(api, os.environ["GITHUB_EVENT_NAME"], event)
        if args.command == "targets":
            require(all(type(n) is int and n > 0 for n in numbers), "invalid PR number")
            if "GITHUB_OUTPUT" in os.environ:
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    output.write("prs=" + json.dumps(sorted(set(numbers))) + "\n")
                    bots, manual = [], []
                    for number in sorted(set(numbers)):
                        (bots if bot(api.get(route(f"pulls/{number}"))) else manual).append(number)
                    output.write("bot_prs=" + json.dumps(bots) + "\n")
                    output.write("manual_prs=" + json.dumps(manual) + "\n")
            print("Current metadata targets:", sorted(set(numbers)))
        else:
            require(args.pr in numbers, "PR does not match notification")
            print(coordinate(api, args.pr, enabled, notification))
    except (Rejected, KeyError, TypeError, OSError, urllib.error.URLError) as error:
        print("Dependabot policy rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
