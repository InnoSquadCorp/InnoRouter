#!/usr/bin/env python3
"""Validate an LCOV report and enforce a repository-owned line floor."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import sys


class CoverageReportError(ValueError):
    """Raised when an LCOV report is incomplete or internally inconsistent."""


def parse_non_negative_integer(value: str, *, field: str, line_number: int) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise CoverageReportError(
            f"line {line_number}: {field} must be a non-negative integer"
        ) from error

    if parsed < 0:
        raise CoverageReportError(
            f"line {line_number}: {field} must be a non-negative integer"
        )
    return parsed


def parse_report(path: Path) -> tuple[int, int, int]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise CoverageReportError(f"cannot read report: {error}") from error

    if not lines:
        raise CoverageReportError("report is empty")

    sources: set[str] = set()
    current_source: str | None = None
    line_hits: dict[int, int] = {}
    declared_found: int | None = None
    declared_hit: int | None = None
    total_found = 0
    total_hit = 0
    record_count = 0

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("TN:"):
            continue

        if line.startswith("SF:"):
            if current_source is not None:
                raise CoverageReportError(
                    f"line {line_number}: previous source record is missing end_of_record"
                )
            current_source = line.removeprefix("SF:")
            if not current_source:
                raise CoverageReportError(f"line {line_number}: SF path must not be empty")
            if current_source in sources:
                raise CoverageReportError(
                    f"line {line_number}: duplicate source record: {current_source}"
                )
            sources.add(current_source)
            line_hits = {}
            declared_found = None
            declared_hit = None
            continue

        if line == "end_of_record":
            if current_source is None:
                raise CoverageReportError(
                    f"line {line_number}: end_of_record has no matching source"
                )
            if declared_found is None or declared_hit is None:
                raise CoverageReportError(
                    f"line {line_number}: {current_source} is missing LF or LH summary"
                )

            computed_entries = len(line_hits)
            computed_hit = sum(hit_count > 0 for hit_count in line_hits.values())
            if (
                declared_found < computed_entries
                or declared_hit < computed_hit
                or declared_hit > declared_found
            ):
                raise CoverageReportError(
                    f"line {line_number}: {current_source} summary is inconsistent "
                    f"(declared {declared_hit}/{declared_found}, "
                    f"DA entries {computed_hit}/{computed_entries})"
                )

            total_found += declared_found
            total_hit += declared_hit
            record_count += 1
            current_source = None
            continue

        if current_source is None:
            raise CoverageReportError(
                f"line {line_number}: coverage data appears outside a source record"
            )

        if line.startswith("DA:"):
            fields = line.removeprefix("DA:").split(",")
            if len(fields) < 2:
                raise CoverageReportError(
                    f"line {line_number}: DA must contain a line number and hit count"
                )
            source_line = parse_non_negative_integer(
                fields[0], field="DA line number", line_number=line_number
            )
            hit_count = parse_non_negative_integer(
                fields[1], field="DA hit count", line_number=line_number
            )
            if source_line == 0:
                raise CoverageReportError(
                    f"line {line_number}: DA line number must be greater than zero"
                )
            if source_line in line_hits:
                raise CoverageReportError(
                    f"line {line_number}: duplicate DA entry for source line {source_line}"
                )
            line_hits[source_line] = hit_count
            continue

        if line.startswith("LF:"):
            if declared_found is not None:
                raise CoverageReportError(f"line {line_number}: duplicate LF summary")
            declared_found = parse_non_negative_integer(
                line.removeprefix("LF:"), field="LF", line_number=line_number
            )
            continue

        if line.startswith("LH:"):
            if declared_hit is not None:
                raise CoverageReportError(f"line {line_number}: duplicate LH summary")
            declared_hit = parse_non_negative_integer(
                line.removeprefix("LH:"), field="LH", line_number=line_number
            )

    if current_source is not None:
        raise CoverageReportError(f"{current_source} is missing end_of_record")
    if record_count == 0:
        raise CoverageReportError("report contains no source records")
    if total_found == 0:
        raise CoverageReportError("report contains no instrumented source lines")

    return total_hit, total_found, record_count


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate an LCOV report and enforce minimum line coverage."
    )
    parser.add_argument("report", type=Path)
    parser.add_argument("--minimum-line-coverage", required=True, type=float)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    minimum = arguments.minimum_line_coverage
    if not math.isfinite(minimum) or minimum < 0 or minimum > 100:
        print(
            "[coverage] Failed: --minimum-line-coverage must be between 0 and 100",
            file=sys.stderr,
        )
        return 2

    try:
        hit, found, records = parse_report(arguments.report)
    except CoverageReportError as error:
        print(f"[coverage] Failed: {error}", file=sys.stderr)
        return 1

    percentage = hit / found * 100
    print(
        f"[coverage] line coverage {percentage:.2f}% "
        f"({hit}/{found} across {records} files); minimum {minimum:.2f}%"
    )
    if percentage + 1e-9 < minimum:
        print(
            f"[coverage] Failed: line coverage is below the required {minimum:.2f}% minimum",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
