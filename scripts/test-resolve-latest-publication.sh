#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/resolve-latest-publication.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/empty"
mkdir -p "$TEMP_DIR/existing/5.0.0" "$TEMP_DIR/existing/5.1.0" "$TEMP_DIR/existing/latest"
mkdir -p "$TEMP_DIR/missing-alias/5.1.0"

expect_output() {
  local name="$1"
  local version="$2"
  local site_dir="$3"
  local expected="$4"
  local output=""
  if ! output="$(bash "$SUBJECT" "$version" "$site_dir" 2>&1)"; then
    echo "[test-resolve-latest-publication] $name: expected success" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" != "$expected" ]]; then
    echo "[test-resolve-latest-publication] $name: output mismatch" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
    exit 1
  fi
  echo "[test-resolve-latest-publication] $name: passed"
}

expect_failure() {
  local name="$1"
  local version="$2"
  local site_dir="$3"
  if bash "$SUBJECT" "$version" "$site_dir" >/dev/null 2>&1; then
    echo "[test-resolve-latest-publication] $name: expected failure" >&2
    exit 1
  fi
  echo "[test-resolve-latest-publication] $name: failed as expected"
}

expect_output \
  'first GA updates latest' \
  5.0.0 \
  "$TEMP_DIR/empty" \
  $'action=update\nlatest_version=5.0.0\nmake_latest=true\nskip_latest=false'
expect_output \
  'older GA preserves latest' \
  4.9.0 \
  "$TEMP_DIR/existing" \
  $'action=preserve\nlatest_version=5.1.0\nmake_latest=false\nskip_latest=true'
expect_output \
  'equal GA rebuild updates latest' \
  5.1.0 \
  "$TEMP_DIR/existing" \
  $'action=update\nlatest_version=5.1.0\nmake_latest=true\nskip_latest=false'
expect_output \
  'higher GA updates latest' \
  5.2.0 \
  "$TEMP_DIR/existing" \
  $'action=update\nlatest_version=5.2.0\nmake_latest=true\nskip_latest=false'
expect_output \
  'prerelease skips both latest surfaces' \
  5.2.0-rc.1 \
  "$TEMP_DIR/existing" \
  $'action=skip\nlatest_version=\nmake_latest=false\nskip_latest=true'

expect_failure 'preserve requires an existing alias' 5.0.0 "$TEMP_DIR/missing-alias"
expect_failure 'invalid version is rejected' 05.0.0 "$TEMP_DIR/existing"
expect_failure 'missing site is rejected' 5.2.0 "$TEMP_DIR/missing"

echo '[test-resolve-latest-publication] All scenarios passed'
