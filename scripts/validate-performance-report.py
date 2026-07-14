#!/usr/bin/env python3
"""Fail-closed validation and diagnostics for performance smoke reports."""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys
from typing import Any


EXPECTED_SAMPLE_NAMES = [
    "navigation_replace_reset_scaling",
    "modal_queue_promote_scaling",
    "middleware_chain_scaling",
    "deep_link_pipeline_scaling",
]


def is_positive_number(value: Any) -> bool:
    return (
        not isinstance(value, bool)
        and isinstance(value, (int, float))
        and math.isfinite(float(value))
        and value > 0
    )


def validate_report(report: Any) -> list[str]:
    if not isinstance(report, dict):
        return ["report root must be an object"]

    errors: list[str] = []
    if report.get("aggregation") != "median":
        errors.append("aggregation must be `median`")
    if report.get("measurementPairs") != 5:
        errors.append("measurementPairs must be 5")
    if not isinstance(report.get("generatedAt"), str) or not report["generatedAt"]:
        errors.append("generatedAt must be a non-empty string")
    if not isinstance(report.get("passed"), bool):
        errors.append("passed must be a boolean")

    memory = report.get("memoryFootprint")
    if not isinstance(memory, dict):
        errors.append("memoryFootprint must be an object")
    else:
        resident_bytes = memory.get("residentBytes")
        if resident_bytes is not None and not (
            type(resident_bytes) is int and resident_bytes >= 0
        ):
            errors.append("memoryFootprint.residentBytes must be null or a non-negative integer")

    samples = report.get("samples")
    if not isinstance(samples, list):
        errors.append("samples must be an array")
        return errors

    sample_names = [
        sample.get("name") if isinstance(sample, dict) else None
        for sample in samples
    ]
    if sample_names != EXPECTED_SAMPLE_NAMES:
        errors.append(
            "samples must contain exactly the four expected scenarios in contract order"
        )

    sample_passes: list[bool] = []
    for index, sample in enumerate(samples):
        label = sample_names[index] or f"sample[{index}]"
        if not isinstance(sample, dict):
            errors.append(f"{label} must be an object")
            continue

        for field in ("smallInput", "largeInput"):
            if type(sample.get(field)) is not int or sample[field] <= 0:
                errors.append(f"{label}.{field} must be a positive integer")

        numeric_fields = (
            "smallMilliseconds",
            "largeMilliseconds",
            "ratio",
            "threshold",
            "largeMaxMilliseconds",
        )
        for field in numeric_fields:
            if not is_positive_number(sample.get(field)):
                errors.append(f"{label}.{field} must be a positive finite number")

        passed = sample.get("passed")
        if not isinstance(passed, bool):
            errors.append(f"{label}.passed must be a boolean")
            continue
        sample_passes.append(passed)

        if all(is_positive_number(sample.get(field)) for field in numeric_fields):
            expected_passed = (
                sample["ratio"] <= sample["threshold"]
                and sample["largeMilliseconds"] <= sample["largeMaxMilliseconds"]
            )
            if passed != expected_passed:
                errors.append(f"{label}.passed is inconsistent with its ratio and cap")

    overall_passed = report.get("passed")
    if isinstance(overall_passed, bool) and len(sample_passes) == len(EXPECTED_SAMPLE_NAMES):
        if overall_passed != all(sample_passes):
            errors.append("report.passed must equal the conjunction of all sample results")

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

    errors = validate_report(report)
    if errors:
        for error in errors:
            print(f"[performance-smoke] Failed: {error}", file=sys.stderr)
        return 1

    failed = [sample for sample in report["samples"] if not sample["passed"]]
    if not failed:
        return 0

    print(
        f"[performance-smoke] Failed: {len(failed)} sample(s) regressed past their threshold",
        file=sys.stderr,
    )
    for sample in failed:
        print(
            "  - {name}: ratio {ratio:.2f} / threshold {threshold:.2f} "
            "(small {small:.2f}ms / large {large:.2f}ms / cap {cap:.2f}ms)".format(
                name=sample["name"],
                ratio=sample["ratio"],
                threshold=sample["threshold"],
                small=sample["smallMilliseconds"],
                large=sample["largeMilliseconds"],
                cap=sample["largeMaxMilliseconds"],
            ),
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
