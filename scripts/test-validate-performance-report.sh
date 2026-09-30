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

output = Path(sys.argv[1])
names = [
    "reducer_transition_throughput",
    "snapshot_roundtrip_throughput",
    "deep_link_match_throughput",
    "inspector_record_export_throughput",
    "scenario_capture_off_on_throughput",
    "history_capacity_scaling",
    "catalog_size_scaling",
]

def sample(name):
    return {
        "name": name,
        "iterations": 100,
        "medianMilliseconds": 1.0,
        "maximumMilliseconds": 2.0,
        "operationsPerSecond": 100_000.0,
        "passed": True,
    }

valid = {
    "schemaVersion": 1,
    "generatedAt": "2026-09-05T00:00:00Z",
    "configuration": "release",
    "aggregation": "median",
    "measurementCount": 5,
    "passed": True,
    "samples": [sample(name) for name in names],
}
fixtures = {"valid": valid}
missing = deepcopy(valid)
missing["samples"].pop()
fixtures["missing"] = missing
inconsistent = deepcopy(valid)
inconsistent["samples"][0]["medianMilliseconds"] = 3.0
fixtures["inconsistent"] = inconsistent
regressed = deepcopy(inconsistent)
regressed["samples"][0]["passed"] = False
regressed["passed"] = False
fixtures["regressed"] = regressed
for name, fixture in fixtures.items():
    (output / f"{name}.json").write_text(json.dumps(fixture), encoding="utf-8")
PY

python3 "$SUBJECT" "$TEMP_DIR/valid.json"

expect_failure() {
  local fixture="$1"
  local diagnostic="$2"
  local output=""
  if output="$(python3 "$SUBJECT" "$TEMP_DIR/$fixture.json" 2>&1)"; then
    echo "[test-performance-report] $fixture unexpectedly passed" >&2
    exit 1
  fi
  [[ "$output" == *"$diagnostic"* ]] || {
    printf '%s\n' "$output" >&2
    exit 1
  }
}

expect_failure missing "exactly the seven canonical scenarios"
expect_failure inconsistent "passed is inconsistent"
expect_failure regressed "Failed thresholds"
echo "[test-performance-report] Validator scenarios passed"
