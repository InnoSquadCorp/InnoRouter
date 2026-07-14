#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/.build/performance-smoke.json}"
SWIFTPM_JOBS="${SWIFTPM_JOBS:-2}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

swift run --jobs "$SWIFTPM_JOBS" --package-path "$ROOT_DIR" \
  InnoRouterPerformanceSmoke --self-test

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

# Enforce the per-sample regression thresholds that
# InnoRouterPerformanceSmoke embeds directly in the report. Small and large
# inputs are measured in alternating pairs and aggregated by median. Each
# sample carries a `threshold` and a computed `ratio` (large median /
# small median); if any sample's ratio exceeds the threshold the smoke
# tool flips `passed` to false. Before this check was wired in, the
# CI job uploaded the JSON but never failed on a regression — so a
# perf blow-up only surfaced by manual artefact inspection.
if ! python3 - "$OUTPUT_PATH" <<'PY'; then
import json
import sys

report_path = sys.argv[1]
with open(report_path, "r", encoding="utf-8") as handle:
    report = json.load(handle)

samples = report.get("samples", [])
failed = [sample for sample in samples if not sample.get("passed", True)]
overall_passed = report.get("passed", True)

if report.get("aggregation") != "median" or report.get("measurementPairs") != 5:
    print("[performance-smoke] Failed: report does not use the required five-pair median aggregation")
    sys.exit(1)

if overall_passed and not failed:
    sys.exit(0)

if not failed:
    print("[performance-smoke] Overall report failed but no individual samples regressed")
    sys.exit(1)

print(f"[performance-smoke] Failed: {len(failed)} sample(s) regressed past their threshold")
for sample in failed:
    cap = sample.get("largeMaxMilliseconds")
    cap_text = (
        f" / cap {cap:.2f}ms" if isinstance(cap, (int, float)) else ""
    )
    print(
        "  - {name}: ratio {ratio:.2f} > threshold {threshold:.2f} "
        "(small {smallMs:.2f}ms / large {largeMs:.2f}ms{cap})".format(
            name=sample.get("name", "<unknown>"),
            ratio=sample.get("ratio", float("nan")),
            threshold=sample.get("threshold", float("nan")),
            smallMs=sample.get("smallMilliseconds", float("nan")),
            largeMs=sample.get("largeMilliseconds", float("nan")),
            cap=cap_text,
        )
    )
sys.exit(1)
PY
    exit 1
fi

if [[ "$SMOKE_EXIT_CODE" -ne 0 ]]; then
  echo "[performance-smoke] Failed: smoke tool exited with status $SMOKE_EXIT_CODE despite a passing report" >&2
  exit "$SMOKE_EXIT_CODE"
fi

echo "[performance-smoke] All scaling ratios within threshold"
