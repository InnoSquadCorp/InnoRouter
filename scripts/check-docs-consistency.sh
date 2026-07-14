#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROADMAP_PATH="$ROOT_DIR/Docs/competitive-analysis-and-roadmap.md"
README_PATH="$ROOT_DIR/README.md"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
REJECTION_CATALOG_PATH="$ROOT_DIR/Sources/InnoRouterCore/InnoRouterCore.docc/Articles/Rejection-Reasons.md"

failures=0

check_absent() {
  local file_path="$1"
  local pattern="$2"
  local message="$3"

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi

  if grep -Fn "$pattern" "$file_path" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $message" >&2
    grep -Fn "$pattern" "$file_path" >&2
    failures=1
  fi
}

check_enum_cases_documented() {
  local source_path="$1"
  local enum_name="$2"

  if [[ ! -f "$source_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $source_path" >&2
    failures=1
    return
  fi

  if [[ ! -f "$REJECTION_CATALOG_PATH" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $REJECTION_CATALOG_PATH" >&2
    failures=1
    return
  fi

  local enum_cases
  enum_cases="$(
    sed -n "/public enum ${enum_name}/,/^}/p" "$source_path" |
      sed -nE 's/^[[:space:]]*case ([A-Za-z_][A-Za-z0-9_]*).*/\1/p' |
      sort -u
  )"
  local catalog_section
  catalog_section="$(
    sed -n "/^### .*${enum_name}/,/^## /p" "$REJECTION_CATALOG_PATH"
  )"

  if [[ -z "$enum_cases" ]]; then
    echo "[check-docs-consistency] Failed: no cases found for $enum_name in $source_path" >&2
    failures=1
    return
  fi
  if [[ -z "$catalog_section" ]]; then
    echo "[check-docs-consistency] Failed: rejection catalog has no ${enum_name} section" >&2
    failures=1
    return
  fi

  while IFS= read -r case_name; do
    if ! grep -F "\`.${case_name}" <<< "$catalog_section" >/dev/null 2>&1; then
      echo "[check-docs-consistency] Failed: rejection catalog omits ${enum_name}.${case_name}" >&2
      failures=1
    fi
  done <<< "$enum_cases"
}

echo "[check-docs-consistency] Checking known roadmap drift claims"
check_absent "$ROADMAP_PATH" 'Remaining gap: `RouteStep` / `FlowPlan` are not yet' \
  "roadmap still claims RouteStep / FlowPlan are not Codable"
check_absent "$ROADMAP_PATH" 'state restoration still requires hand-rolling a plan.' \
  "roadmap still claims flow state restoration requires manual planning"
check_absent "$ROADMAP_PATH" 'requires hand-rolling commands.' \
  "roadmap still claims multi-step deep-link rehydration needs hand-rolled commands"
check_absent "$ROADMAP_PATH" '`FlowIntent` parallels were intentionally skipped' \
  "roadmap still claims FlowIntent ergonomic parity was skipped entirely"
check_absent "$ROADMAP_PATH" '| P2 | UIKit escape hatch | adoption path | large | open |' \
  "roadmap still marks the UIKit escape hatch as open"
check_absent "$README_PATH" 'Separate product decision' \
  "README still claims the UIKit escape hatch needs a product decision"
check_absent "$CHANGELOG_PATH" 'awaiting product decision' \
  "changelog still claims the UIKit escape hatch is awaiting product decision"
check_absent "$CHANGELOG_PATH" 'remains open behind' \
  "changelog still claims the UIKit escape hatch remains open"
check_absent "$ROADMAP_PATH" '3.0.0 release candidate' \
  "roadmap still claims 3.0.0 is the release candidate"
check_absent "$ROADMAP_PATH" 'debounce deferred' \
  "roadmap still claims debounce remains deferred"
check_absent "$ROADMAP_PATH" '.debounce remains open' \
  "roadmap still claims debounce remains open"
check_absent "$ROADMAP_PATH" 'Next gap is P3-4' \
  "roadmap still contains stale next-gap positioning"
check_absent "$CHANGELOG_PATH" '### Deferred to 4.1' \
  "changelog still has a 4.1 deferred section after the 4.0 release sweep"
check_absent "$README_PATH" 'deferred from P3-4' \
  "README still claims debounce is deferred from P3-4"

echo "[check-docs-consistency] Checking rejection catalog enum coverage"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterCore/NavigationInterception.swift" \
  "NavigationCancellationReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterCore/ModalInterception.swift" \
  "ModalCancellationReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterCore/FlowRejectionReason.swift" \
  "FlowRejectionReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterSpatial/SceneContracts.swift" \
  "SceneRejectionReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterDeepLink/DeepLinkPipeline.swift" \
  "DeepLinkRejectionReason"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "[check-docs-consistency] Known drift-prone claims are up to date"
