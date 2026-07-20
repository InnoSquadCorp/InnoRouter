#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/validate-coverage-report.py"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

write_fixture() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$TEMP_DIR/$name.lcov"
}

expect_pass() {
  local name="$1"
  local minimum="$2"
  if ! python3 "$SUBJECT" "$TEMP_DIR/$name.lcov" --minimum-line-coverage "$minimum"; then
    echo "[test-validate-coverage-report] $name: expected success" >&2
    exit 1
  fi
  echo "[test-validate-coverage-report] $name: passed"
}

expect_fail() {
  local name="$1"
  local minimum="$2"
  local expected_message="$3"
  local output=""
  if output="$(python3 "$SUBJECT" "$TEMP_DIR/$name.lcov" --minimum-line-coverage "$minimum" 2>&1)"; then
    echo "[test-validate-coverage-report] $name: expected failure" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    echo "[test-validate-coverage-report] $name: missing diagnostic $expected_message" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  echo "[test-validate-coverage-report] $name: failed as expected"
}

write_fixture valid \
  'SF:/repo/Sources/Feature.swift' \
  'DA:1,1' \
  'DA:2,2' \
  'DA:3,0' \
  'DA:4,1' \
  'LF:4' \
  'LH:3' \
  'end_of_record'

write_fixture below-floor \
  'SF:/repo/Sources/Feature.swift' \
  'DA:1,1' \
  'DA:2,0' \
  'DA:3,0' \
  'DA:4,0' \
  'LF:4' \
  'LH:1' \
  'end_of_record'

write_fixture inconsistent \
  'SF:/repo/Sources/Feature.swift' \
  'DA:1,1' \
  'DA:2,0' \
  'LF:2' \
  'LH:3' \
  'end_of_record'

write_fixture malformed \
  'SF:/repo/Sources/Feature.swift' \
  'DA:not-a-line,1' \
  'LF:1' \
  'LH:1' \
  'end_of_record'

write_fixture missing-end \
  'SF:/repo/Sources/Feature.swift' \
  'DA:1,1' \
  'LF:1' \
  'LH:1'

: > "$TEMP_DIR/empty.lcov"

expect_pass valid 75
expect_fail below-floor 75 'below the required 75.00% minimum'
expect_fail inconsistent 0 'summary is inconsistent'
expect_fail malformed 0 'DA line number must be a non-negative integer'
expect_fail missing-end 0 'missing end_of_record'
expect_fail empty 0 'report is empty'

echo '[test-validate-coverage-report] All scenarios passed'
