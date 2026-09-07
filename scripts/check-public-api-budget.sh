#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_DIR="${1:-$ROOT_DIR/Baselines/PublicAPI}"
BUDGET_FILE="$ROOT_DIR/Baselines/PublicAPI/symbol-budgets.tsv"

[[ -f "$BUDGET_FILE" ]] || {
  echo "[check-public-api-budget] Missing budget file: $BUDGET_FILE" >&2
  exit 1
}

failed=0
budget_count=0

while IFS=$'\t' read -r product_name maximum_symbols remainder; do
  [[ -n "$product_name" ]] || continue
  [[ "$product_name" == \#* ]] && continue

  budget_count=$((budget_count + 1))
  baseline_path="$BASELINE_DIR/${product_name}.txt"

  if [[ ! -f "$baseline_path" ]]; then
    echo "[check-public-api-budget] Missing baseline for $product_name" >&2
    failed=1
    continue
  fi
  if [[ ! "$maximum_symbols" =~ ^[0-9]+$ ]]; then
    echo "[check-public-api-budget] Invalid budget for $product_name: $maximum_symbols" >&2
    failed=1
    continue
  fi

  symbol_count="$(grep -c '^symbol |' "$baseline_path" || true)"
  printf '[check-public-api-budget] %s: %s/%s public symbols\n' \
    "$product_name" "$symbol_count" "$maximum_symbols"

  if (( symbol_count > maximum_symbols )); then
    echo "[check-public-api-budget] Public API budget exceeded for $product_name" >&2
    echo "[check-public-api-budget] Review and reduce the surface, or update the budget in the same deliberate change." >&2
    failed=1
  fi
done <"$BUDGET_FILE"

baseline_count="$(find "$BASELINE_DIR" -maxdepth 1 -type f -name '*.txt' | wc -l | tr -d ' ')"
if [[ "$baseline_count" -ne "$budget_count" ]]; then
  echo "[check-public-api-budget] Expected one budget for each public product ($budget_count budgets, $baseline_count baselines)" >&2
  failed=1
fi

if grep -Eq '(^|[^[:alnum:]_])RouterLinkEvent([^[:alnum:]_]|$)' "$BASELINE_DIR/InnoRouter.txt"; then
  echo "[check-public-api-budget] Duplicate RouterLinkEvent vocabulary leaked into the public API" >&2
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "[check-public-api-budget] Public API budgets match"
