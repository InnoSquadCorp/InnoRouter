#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/validate-performance-report.py"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

python3 - "$TEMP_DIR" <<'PY'
from copy import deepcopy
import json
from pathlib import Path
import sys

output_dir = Path(sys.argv[1])
names = [
    "navigation_replace_reset_scaling",
    "modal_queue_promote_scaling",
    "middleware_chain_scaling",
    "deep_link_pipeline_scaling",
]


def sample(name: str) -> dict[str, object]:
    return {
        "name": name,
        "smallInput": 1,
        "largeInput": 2,
        "smallMilliseconds": 1.0,
        "largeMilliseconds": 2.0,
        "ratio": 2.0,
        "threshold": 3.0,
        "largeMaxMilliseconds": 10.0,
        "passed": True,
    }


valid = {
    "generatedAt": "2026-07-15T00:00:00Z",
    "aggregation": "median",
    "measurementPairs": 5,
    "passed": True,
    "memoryFootprint": {"residentBytes": 1},
    "samples": [sample(name) for name in names],
}

fixtures = {"valid": valid}

empty = deepcopy(valid)
empty["samples"] = []
fixtures["empty"] = empty

missing_sample = deepcopy(valid)
missing_sample["samples"].pop()
fixtures["missing-sample"] = missing_sample

missing_field = deepcopy(valid)
del missing_field["samples"][0]["ratio"]
fixtures["missing-field"] = missing_field

inconsistent = deepcopy(valid)
inconsistent["samples"][0]["ratio"] = 4.0
fixtures["inconsistent"] = inconsistent

regression = deepcopy(valid)
regression["samples"][0]["ratio"] = 4.0
regression["samples"][0]["passed"] = False
regression["passed"] = False
fixtures["regression"] = regression

for name, fixture in fixtures.items():
    (output_dir / f"{name}.json").write_text(
        json.dumps(fixture),
        encoding="utf-8",
    )
PY

expect_pass() {
  local name="$1"
  if ! python3 "$SUBJECT" "$TEMP_DIR/$name.json"; then
    echo "[test-validate-performance-report] $name: expected success" >&2
    exit 1
  fi
  echo "[test-validate-performance-report] $name: passed"
}

expect_fail() {
  local name="$1"
  local expected_message="$2"
  local output=""
  if output="$(python3 "$SUBJECT" "$TEMP_DIR/$name.json" 2>&1)"; then
    echo "[test-validate-performance-report] $name: expected failure" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    echo "[test-validate-performance-report] $name: missing diagnostic $expected_message" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  echo "[test-validate-performance-report] $name: failed as expected"
}

expect_pass valid
expect_fail empty 'exactly the four expected scenarios'
expect_fail missing-sample 'exactly the four expected scenarios'
expect_fail missing-field 'ratio must be a positive finite number'
expect_fail inconsistent 'passed is inconsistent with its ratio and cap'
expect_fail regression '1 sample(s) regressed past their threshold'

echo '[test-validate-performance-report] All scenarios passed'
