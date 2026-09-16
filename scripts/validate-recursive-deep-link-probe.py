#!/usr/bin/env python3
"""Validate the recursive deep-link probe's semantic result envelope."""

from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any


PREFIX = "[recursive-deep-link-probe] "
EXPECTED = {
    "schemaVersion": 1,
    "selfCatalog": ["leaf"],
    "selfLocalResolved": True,
    "selfURLRoundTrips": True,
    "mutualCatalog": ["leaf", "toB.leaf"],
    "growingCatalogComplete": False,
    "growingCatalogEntries": [],
    "growingResolved": False,
    "growingDecision": "traversal-limit-exceeded",
}


def validate_output(output: str) -> list[str]:
    reports = [line[len(PREFIX) :] for line in output.splitlines() if line.startswith(PREFIX)]
    if len(reports) != 1:
        return [f"expected exactly one semantic report, found {len(reports)}"]
    try:
        report: Any = json.loads(reports[0])
    except json.JSONDecodeError as error:
        return [f"semantic report is not valid JSON: {error}"]
    if report != EXPECTED:
        return ["semantic report does not match the recursive traversal contract"]
    return []


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate-recursive-deep-link-probe.py <probe-output>", file=sys.stderr)
        return 2
    try:
        output = Path(sys.argv[1]).read_text(encoding="utf-8")
    except OSError as error:
        print(f"[recursive-deep-link-gate] Failed: cannot read output: {error}", file=sys.stderr)
        return 1
    errors = validate_output(output)
    for error in errors:
        print(f"[recursive-deep-link-gate] Failed: {error}", file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
