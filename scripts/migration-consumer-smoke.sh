#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${SWIFTPM_JOBS:-2}"
SCRATCH_ROOT="$ROOT_DIR/.build/migration-consumer"
mkdir -p "$SCRATCH_ROOT"
AFTER_SCRATCH="$(mktemp -d "$SCRATCH_ROOT/after.XXXXXX")"
trap 'rm -rf "$AFTER_SCRATCH"' EXIT

echo "[migration-smoke] Running the exact published 5.2.1 consumer"
before_output="$(
  swift run \
    --package-path "$ROOT_DIR/MigrationSmoke/Before" \
    --scratch-path "$SCRATCH_ROOT/before" \
    --jobs "$JOBS" \
    --quiet \
    LegacyMigrationProbe
)"

echo "[migration-smoke] Running the current macro-first 6.0 consumer"
after_output="$(
  swift run \
    --package-path "$ROOT_DIR/MigrationSmoke/After" \
    --scratch-path "$AFTER_SCRATCH" \
    --jobs "$JOBS" \
    --quiet \
    CanonicalMigrationProbe
)"

expected='["home","settings"]'
if [[ "$before_output" != "$expected" ]]; then
  echo "[migration-smoke] Unexpected 5.2.1 behavior: $before_output" >&2
  exit 1
fi
if [[ "$after_output" != "$expected" ]]; then
  echo "[migration-smoke] Unexpected 6.0 behavior: $after_output" >&2
  exit 1
fi
if [[ "$before_output" != "$after_output" ]]; then
  echo "[migration-smoke] Migrated scenario changed behavior" >&2
  exit 1
fi

echo "[migration-smoke] 5.2.1 and macro-first 6.0 both produced $expected"
