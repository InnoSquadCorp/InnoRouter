#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/.build/performance-smoke.json}"
SWIFTPM_JOBS="${SWIFTPM_JOBS:-2}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

swift run --jobs "$SWIFTPM_JOBS" --package-path "$ROOT_DIR" \
  InnoRouterPerformanceSmoke --self-test
bash "$ROOT_DIR/scripts/test-validate-performance-report.sh"

TEMP_OUTPUT="$(mktemp "$(dirname "$OUTPUT_PATH")/.performance-smoke.XXXXXX")"
cleanup() {
  rm -f "$TEMP_OUTPUT"
}
trap cleanup EXIT

set +e
swift run --jobs "$SWIFTPM_JOBS" --package-path "$ROOT_DIR" \
  InnoRouterPerformanceSmoke --output "$TEMP_OUTPUT"
SMOKE_EXIT_CODE=$?
set -e

if [[ ! -s "$TEMP_OUTPUT" ]]; then
  echo "[performance-smoke] Failed: smoke tool exited without a report (status $SMOKE_EXIT_CODE)" >&2
  exit 1
fi

mv "$TEMP_OUTPUT" "$OUTPUT_PATH"
trap - EXIT

echo "Performance smoke report written to $OUTPUT_PATH"
cat "$OUTPUT_PATH"

# Enforce the exact four-scenario report schema as well as the per-sample
# threshold and absolute cap. Small and large inputs are measured in alternating
# pairs; `ratio` is the median of the five per-pair large/small ratios.
if ! python3 "$ROOT_DIR/scripts/validate-performance-report.py" "$OUTPUT_PATH"; then
  exit 1
fi

if [[ "$SMOKE_EXIT_CODE" -ne 0 ]]; then
  echo "[performance-smoke] Failed: smoke tool exited with status $SMOKE_EXIT_CODE despite a passing report" >&2
  exit "$SMOKE_EXIT_CODE"
fi

echo "[performance-smoke] All scaling ratios within threshold"
