#!/usr/bin/env python3
"""Prevent called workflows from cancelling their siblings in a release run."""

import re
from pathlib import Path


def validate(workflows):
    prefixes = set()
    for name, source in workflows:
        if not re.search(r"^  workflow_call:", source, re.MULTILINE):
            continue
        group = re.search(r"^  group: (.+)$", source, re.MULTILINE)
        if group is None:
            raise ValueError(f"{name}: missing reusable-workflow concurrency group")
        prefix = group[1].split("${{", 1)[0].strip(" \"'")
        if not prefix or prefix in prefixes:
            raise ValueError(f"{name}: reusable workflows need distinct static concurrency prefixes")
        prefixes.add(prefix)


def self_test():
    shared = "on:\n  workflow_call:\nconcurrency:\n  group: ${{ github.workflow }}-${{ github.ref }}\n"
    unique = shared.replace("group: ", "group: coverage-")
    for invalid in [[("old", shared)], [("one", unique), ("two", unique)]]:
        try:
            validate(invalid)
        except ValueError:
            continue
        raise AssertionError("The collision negative control unexpectedly passed")
    validate([("coverage", unique), ("performance", unique.replace("coverage-", "performance-"))])


self_test()
root = Path(__file__).resolve().parent.parent
validate((path.name, path.read_text()) for path in sorted((root / ".github/workflows").glob("*.yml")))
print("[workflow-concurrency] Reusable workflows have distinct concurrency namespaces")
