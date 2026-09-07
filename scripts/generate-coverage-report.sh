#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/coverage.lcov}"
FULL_OUTPUT_PATH="${2:-}"

for required in find sort swift xcrun; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "[coverage] $required is required" >&2
    exit 1
  fi
done

cd "$ROOT_DIR"

bin_path="$(swift build --show-bin-path)"
prof_data="$bin_path/codecov/default.profdata"
if [[ ! -f "$prof_data" ]]; then
  echo "[coverage] default.profdata not found at $prof_data" >&2
  exit 1
fi

test_bins=()
while IFS= read -r xctest_bundle; do
  bundle_name="$(basename "$xctest_bundle" .xctest)"
  test_bin="$xctest_bundle/Contents/MacOS/$bundle_name"
  if [[ ! -x "$test_bin" ]]; then
    echo "[coverage] Test binary not executable at $test_bin" >&2
    exit 1
  fi
  if [[ "$test_bin" -nt "$prof_data" ]]; then
    echo "[coverage] Test binary is newer than the coverage profile: $test_bin" >&2
    echo "[coverage] Re-run 'swift test --enable-code-coverage --jobs 2' before exporting" >&2
    exit 1
  fi
  test_bins+=("$test_bin")
done < <(find "$bin_path" -maxdepth 1 -type d -name '*.xctest' | sort)

if [[ "${#test_bins[@]}" -eq 0 ]]; then
  echo "[coverage] .xctest bundle not found under $bin_path" >&2
  exit 1
fi

llvm_cov_args=("${test_bins[0]}")
for test_bin in "${test_bins[@]:1}"; do
  llvm_cov_args+=(-object "$test_bin")
done

# Native renderers, scene lifecycle bridges, and compiler-plugin bootstrap
# code are validated by the all-platform Xcode matrix, downstream consumer
# builds, and fail-fast probes. Counting their target-specific inactive
# branches in the host-only numerical floor would reward macOS reachability
# rather than portable behavior. Deterministic router, deep-link, policy,
# restoration, inspector-model, macro-expansion, and testing logic remains in
# this report.
coverage_exclusions='Tests|\.build|Examples|ExamplesSmoke|InternalExecutionTrace\.swift|Sources/[^/]*FailFastProbe/|Sources/InnoRouterSwiftUI/(EnvironmentMissingPolicy|EnvironmentRouter|EnvironmentRouterState|PlatformHostingAdapters|RouterDeepLinkHandling|RouterHost|RouterSceneDriver|RouterSceneHost|RouterSceneLifecycle|RouterStoreStackSurface|RouterTabHost|RouterSplitHost)\.swift|Sources/InnoRouterInspector/(RouterInspectorView|RouterInspectorScenarioSection)\.swift|Sources/InnoRouterMacrosPlugin/InnoRouterMacrosPlugin\.swift|Sources/InnoRouterPatternSupport/RoutePattern\.swift'
full_coverage_exclusions='Tests|\.build|Examples|ExamplesSmoke|Sources/[^/]*FailFastProbe/|Sources/InnoRouterPerformanceSmoke/'

echo "[coverage] Using profdata: $prof_data"
printf '[coverage] Using binary: %s\n' "${test_bins[@]}"

xcrun llvm-cov export \
  "${llvm_cov_args[@]}" \
  -instr-profile "$prof_data" \
  -format=lcov \
  -ignore-filename-regex="$coverage_exclusions" \
  > "$OUTPUT_PATH"

echo "[coverage] Wrote $OUTPUT_PATH ($(wc -l < "$OUTPUT_PATH" | tr -d ' ') lines)"

if [[ -n "$FULL_OUTPUT_PATH" ]]; then
  xcrun llvm-cov export \
    "${llvm_cov_args[@]}" \
    -instr-profile "$prof_data" \
    -format=lcov \
    -ignore-filename-regex="$full_coverage_exclusions" \
    > "$FULL_OUTPUT_PATH"
  echo "[coverage] Wrote comprehensive report $FULL_OUTPUT_PATH ($(wc -l < "$FULL_OUTPUT_PATH" | tr -d ' ') lines)"
fi
