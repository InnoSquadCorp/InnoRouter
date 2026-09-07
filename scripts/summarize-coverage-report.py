#!/usr/bin/env python3
"""Create component-level visibility for gated and comprehensive LCOV reports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
from typing import Any


MACRO_MODULES = {
    "InnoRouterMacros",
    "InnoRouterMacrosPlugin",
    "InnoRouterPatternSupport",
}


def group_for(source: str) -> str:
    match = re.search(r"/Sources/([^/]+)/", source)
    if not match:
        return "Other"
    module = match.group(1)
    return "Macros" if module in MACRO_MODULES else module


def parse(path: Path) -> dict[str, Any]:
    groups: dict[str, dict[str, int]] = {}
    source: str | None = None
    found: int | None = None
    hit: int | None = None
    files = 0

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            source = line[3:]
            found = None
            hit = None
        elif line.startswith("LF:"):
            found = int(line[3:])
        elif line.startswith("LH:"):
            hit = int(line[3:])
        elif line == "end_of_record":
            if source is None or found is None or hit is None:
                raise ValueError(f"incomplete LCOV record in {path}")
            group = groups.setdefault(group_for(source), {"files": 0, "found": 0, "hit": 0})
            group["files"] += 1
            group["found"] += found
            group["hit"] += hit
            files += 1
            source = None

    if source is not None or files == 0:
        raise ValueError(f"invalid or empty LCOV report: {path}")

    def present(values: dict[str, int]) -> dict[str, int | float]:
        found_lines = values["found"]
        percentage = values["hit"] / found_lines * 100 if found_lines else 100.0
        return {
            "files": values["files"],
            "foundLines": found_lines,
            "hitLines": values["hit"],
            "lineCoveragePercent": round(percentage, 2),
        }

    totals = {
        "files": sum(group["files"] for group in groups.values()),
        "found": sum(group["found"] for group in groups.values()),
        "hit": sum(group["hit"] for group in groups.values()),
    }
    return {
        "totals": present(totals),
        "components": {
            name: present(groups[name])
            for name in sorted(groups)
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gated", required=True, type=Path)
    parser.add_argument("--comprehensive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    gated = parse(args.gated)
    comprehensive = parse(args.comprehensive)
    report = {
        "schemaVersion": 1,
        "gated": gated,
        "comprehensive": comprehensive,
        "visibilityDelta": {
            "additionalFiles": comprehensive["totals"]["files"] - gated["totals"]["files"],
            "additionalFoundLines": comprehensive["totals"]["foundLines"] - gated["totals"]["foundLines"],
        },
    }
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        "[coverage] comprehensive visibility adds "
        f"{report['visibilityDelta']['additionalFiles']} files and "
        f"{report['visibilityDelta']['additionalFoundLines']} instrumented lines"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
