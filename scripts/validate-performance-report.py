#!/usr/bin/env python3
"""Fail closed on malformed or regressed InnoRouter v6 performance reports."""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys
from typing import Any


EXPECTED_NAMES = [
    "reducer_transition_throughput",
    "snapshot_roundtrip_throughput",
    "deep_link_match_throughput",
    "inspector_record_export_throughput",
    "scenario_capture_off_on_throughput",
    "history_capacity_scaling",
    "catalog_size_scaling",
]


def positive_number(value: Any) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(float(value))
        and value > 0
    )


def validate(report: Any) -> list[str]:
    if not isinstance(report, dict):
        return ["report root must be an object"]

    errors: list[str] = []
    if report.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    if report.get("configuration") != "release":
        errors.append("configuration must be `release`")
    if report.get("aggregation") != "median":
        errors.append("aggregation must be `median`")
    if report.get("measurementCount") != 5:
        errors.append("measurementCount must be 5")
    if not isinstance(report.get("generatedAt"), str) or not report["generatedAt"]:
        errors.append("generatedAt must be a non-empty string")

    samples = report.get("samples")
    if not isinstance(samples, list):
        return errors + ["samples must be an array"]
    names = [sample.get("name") if isinstance(sample, dict) else None for sample in samples]
    if names != EXPECTED_NAMES:
        errors.append("samples must contain exactly the seven canonical scenarios in order")

    passes: list[bool] = []
    for index, sample in enumerate(samples):
        label = names[index] if index < len(names) and names[index] else f"sample[{index}]"
        if not isinstance(sample, dict):
            errors.append(f"{label} must be an object")
            continue
        if type(sample.get("iterations")) is not int or sample["iterations"] <= 0:
            errors.append(f"{label}.iterations must be a positive integer")
        for field in (
            "medianMilliseconds",
            "maximumMilliseconds",
            "operationsPerSecond",
        ):
            if not positive_number(sample.get(field)):
                errors.append(f"{label}.{field} must be a positive finite number")
        passed = sample.get("passed")
        if not isinstance(passed, bool):
            errors.append(f"{label}.passed must be a boolean")
            continue
        passes.append(passed)
        if positive_number(sample.get("medianMilliseconds")) and positive_number(
            sample.get("maximumMilliseconds")
        ):
            expected = sample["medianMilliseconds"] <= sample["maximumMilliseconds"]
            if passed != expected:
                errors.append(f"{label}.passed is inconsistent with its threshold")

    overall = report.get("passed")
    if not isinstance(overall, bool):
        errors.append("passed must be a boolean")
    elif len(passes) == len(EXPECTED_NAMES) and overall != all(passes):
        errors.append("passed must equal all sample results")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate-performance-report.py <report.json>", file=sys.stderr)
        return 2
    try:
        report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"[performance-smoke] Failed: cannot read report: {error}", file=sys.stderr)
        return 1

    errors = validate(report)
    for error in errors:
        print(f"[performance-smoke] Failed: {error}", file=sys.stderr)
    if errors:
        return 1
    if not report["passed"]:
        failed = [sample["name"] for sample in report["samples"] if not sample["passed"]]
        print(f"[performance-smoke] Failed thresholds: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
