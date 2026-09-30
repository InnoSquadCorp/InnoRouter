#!/usr/bin/env python3
"""Require the current Inspector UI tests, not merely a passing test count."""

import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tree = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
required = {
    "InspectorUITests/testInspectorRelease600UserFlow()",
    "InspectorUITests/testInspectorMountedLocaleBidirectionalStatePreservation()",
    "InspectorUITests/testInspectorPolicyPreparationAcknowledgesRequestedState()",
}

if (summary.get("result") != "Passed" or summary.get("passedTests", 0) < len(required)
        or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0
        or summary.get("expectedFailures") != 0):
    raise SystemExit("Inspector UI must execute and pass without skips")


def passed_tests(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
            yield node.get("nodeIdentifier")
        for value in node.values():
            yield from passed_tests(value)
    elif isinstance(node, list):
        for value in node:
            yield from passed_tests(value)


missing = required - set(passed_tests(tree))
if missing:
    raise SystemExit(f"Missing current Inspector UI tests: {sorted(missing)}")
print("[inspector-ui] All three current test cases passed without skips")
