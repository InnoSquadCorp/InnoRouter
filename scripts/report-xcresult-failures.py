#!/usr/bin/env python3
"""Print every failure an xcresult summary records.

`xcodebuild -quiet` names a failing test but not the assertion that failed, and
the result bundle is readable only after downloading the job's artifact. This
prints each failure's test and message into the job log so a failed run is
diagnosable from the log alone.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: report-xcresult-failures.py <summary.json>", file=sys.stderr)
        return 2

    summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    failures = summary.get("testFailures") or []
    for failure in failures:
        target = failure.get("targetName")
        test = failure.get("testIdentifierString") or failure.get("testName") or "<unknown test>"
        text = failure.get("failureText") or "<no failure text>"
        prefix = f"{target}/" if target else ""
        print(f"[xcresult] FAILED {prefix}{test}: {text}")
    if not failures:
        print(f"[xcresult] result={summary.get('result')} with no recorded test failures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
