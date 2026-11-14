#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/.build/performance-smoke.json}"
SWIFTPM_JOBS="${SWIFTPM_JOBS:-2}"

bash "$ROOT_DIR/scripts/verify-json-key-fast-path.sh"
TESTING_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"
# Xcode ships Swift Testing as a platform framework. An open-source toolchain
# selected through TOOLCHAINS ships it as a dylib inside the toolchain instead,
# so the same executable needs that directory on the library path.
TOOLCHAIN_TESTING_LIBRARIES="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/macosx/testing"

run_performance_executable() {
  local library_path="${DYLD_LIBRARY_PATH:-}"
  if [[ -d "$TOOLCHAIN_TESTING_LIBRARIES" ]]; then
    library_path="$TOOLCHAIN_TESTING_LIBRARIES${library_path:+:$library_path}"
  fi
  DYLD_FRAMEWORK_PATH="$TESTING_FRAMEWORKS${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" \
    DYLD_LIBRARY_PATH="$library_path" \
    "$PERFORMANCE_EXECUTABLE" "$@"
}
RELEASE_BIN_DIR="$(swift build -c release --jobs "$SWIFTPM_JOBS" --package-path "$ROOT_DIR" --show-bin-path)"
PERFORMANCE_EXECUTABLE="$RELEASE_BIN_DIR/InnoRouterPerformanceSmoke"

mkdir -p "$(dirname "$OUTPUT_PATH")"

swift build -c release --jobs "$SWIFTPM_JOBS" --package-path "$ROOT_DIR" \
  --product InnoRouterPerformanceSmoke
run_performance_executable --self-test
bash "$ROOT_DIR/scripts/test-validate-performance-report.sh"

TEMP_OUTPUT="$(mktemp "$(dirname "$OUTPUT_PATH")/.performance-smoke.XXXXXX")"
cleanup() {
  rm -f "$TEMP_OUTPUT"
}
trap cleanup EXIT

set +e
run_performance_executable --output "$TEMP_OUTPUT"
SMOKE_EXIT_CODE=$?
set -e

if [[ ! -s "$TEMP_OUTPUT" ]]; then
  echo "[performance-smoke] Failed: no report was produced (status $SMOKE_EXIT_CODE)" >&2
  exit 1
fi

mv "$TEMP_OUTPUT" "$OUTPUT_PATH"
trap - EXIT

python3 "$ROOT_DIR/scripts/validate-performance-report.py" "$OUTPUT_PATH"
cat "$OUTPUT_PATH"

if [[ "$SMOKE_EXIT_CODE" -ne 0 ]]; then
  exit "$SMOKE_EXIT_CODE"
fi

echo "[performance-smoke] Canonical runtime baselines passed"

# Attribution is a separate process after the canonical report is validated.
# A diagnostic crash/failure must neither suppress that report nor change its gate.
if ! run_performance_executable --profile-json-keys; then
  echo "[performance-smoke] Warning: optional JSON-key attribution failed" >&2
fi
