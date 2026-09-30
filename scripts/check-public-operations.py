#!/usr/bin/env python3
"""Validate the repository's reviewed dependency/discovery configuration subset.

The .yml files use JSON (valid YAML) so CI needs only Python's standard library.
This is a repository contract check, not a replacement for the official parsers.
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIRS = {"/", "/ConsumerSmoke", "/NativeSceneSmoke"}


def check(root=ROOT):
    bot = json.loads((root / ".github/dependabot.yml").read_text())
    if set(bot) != {"version", "updates"} or bot["version"] != 2 or len(bot["updates"]) != 2:
        raise ValueError("expected the two reviewed Dependabot ecosystems")
    ecosystems = {item["package-ecosystem"]: item for item in bot["updates"]}
    if set(ecosystems) != {"swift", "github-actions"}:
        raise ValueError("unexpected Dependabot ecosystem")
    for name, item in ecosystems.items():
        allowed = {"package-ecosystem", "schedule", "open-pull-requests-limit", "groups", "commit-message", "labels"}
        allowed.add("directories" if name == "swift" else "directory")
        if set(item) != allowed:
            raise ValueError("unreviewed or missing Dependabot configuration key")
        time = "09:30" if name == "swift" else "09:00"
        if item["schedule"] != {"interval": "weekly", "day": "monday", "time": time, "timezone": "Asia/Seoul"}:
            raise ValueError("dependency updates must follow the shared weekly schedule")
        if item["open-pull-requests-limit"] != (3 if name == "swift" else 5):
            raise ValueError("unexpected version-update PR limit")
        prefix = "chore(deps)" if name == "swift" else "chore(ci)"
        if item["commit-message"] != {"prefix": prefix}:
            raise ValueError("unsupported commit-message configuration")
        group_name = "swift-minor-patch" if name == "swift" else "actions-minor-patch"
        group = {"patterns": ["*"], "update-types": ["minor", "patch"]}
        if name == "swift":
            group["exclude-patterns"] = ["github.com/swiftlang/swift-syntax"]
        if item["groups"] != {group_name: group}:
            raise ValueError("major/toolchain updates must stay outside low-risk groups")
    swift = ecosystems["swift"]
    if len(swift["directories"]) != len(SWIFT_DIRS) or set(swift["directories"]) != SWIFT_DIRS:
        raise ValueError("track only reviewed live manifests; exclude historical/template fixtures")
    for directory in swift["directories"]:
        if not (root / directory.lstrip("/") / "Package.swift").is_file():
            raise ValueError("tracked Swift directory has no live manifest")
    if "release-validation" not in swift["labels"] or ecosystems["github-actions"]["directory"] != "/":
        raise ValueError("Swift updates require exhaustive validation; Actions must use root")
    pin = re.search(r'swift-syntax\.git", \.upToNextMinor\(from: "([0-9.]+)"', (root / "Package.swift").read_text())
    if not pin:
        raise ValueError("SwiftSyntax must retain a reviewed release-line constraint")
    minimum = tuple(map(int, pin[1].split('.')))
    resolved = []
    for name in ("Package.resolved", "ConsumerSmoke/Package.resolved",
                 "NativeSceneSmoke/NativeSceneSmoke.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"):
        lock = json.loads((root / name).read_text())
        syntax = [p for p in lock["pins"] if p["identity"] == "swift-syntax"]
        if len(syntax) != 1 or not re.fullmatch(r'[0-9a-f]{40}', syntax[0]["state"].get("revision", "")):
            raise ValueError("live SwiftSyntax lock must contain exactly one immutable revision")
        resolved.append(syntax[0]["state"])
    if any(state != resolved[0] for state in resolved):
        raise ValueError("SwiftSyntax update requires all live consumer locks in the same PR")
    version = tuple(map(int, resolved[0]["version"].split('.')))
    if version[:2] != minimum[:2] or version < minimum:
        raise ValueError("SwiftSyntax lock is outside the manifest release line")
    spi = json.loads((root / ".spi.yml").read_text())
    if type(spi.get("version")) is not int or spi != {"version": 1, "external_links": {"documentation": "https://innosquadcorp.github.io/InnoRouter/latest/"}}:
        raise ValueError("SPI must use the reviewed existing DocC hosting contract")
    for path in ("LICENSE", "CONTRIBUTING.md", "SECURITY.md", "RELEASING.md",
                 ".github/PULL_REQUEST_TEMPLATE.md", ".github/ISSUE_TEMPLATE/bug_report.yml",
                 ".github/ISSUE_TEMPLATE/feature_request.yml", "Docs/automation-policy.md"):
        if not (root / path).is_file():
            raise ValueError("missing public operations file: " + path)
    if not (root / "LICENSE").read_text().startswith("MIT License\n\nCopyright (c) 2025 InnoSquad\n"):
        raise ValueError("license changes require separate legal review")


if __name__ == "__main__":
    try:
        check()
        print("Public operations and dependency update contracts passed.")
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"Public operations policy rejected: {error}", file=sys.stderr)
        sys.exit(1)
