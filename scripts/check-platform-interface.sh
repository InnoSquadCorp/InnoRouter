#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$ROOT_DIR/Baselines/PlatformAPI/targets.tsv"

usage() {
  cat <<'EOF'
Usage: ./scripts/check-platform-interface.sh <derived-data-path> <platform-name>

Validates the library-evolution interfaces emitted by the Xcode platform
consumer matrix for InnoRouter's three public products.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

derived_data="$1"
platform_name="$2"

if [[ ! -d "$derived_data/Build/Products" ]]; then
  echo "[platform-interface] Missing products directory under $derived_data" >&2
  exit 1
fi
if [[ ! -f "$BASELINE" ]]; then
  echo "[platform-interface] Missing target baseline: $BASELINE" >&2
  exit 1
fi

baseline_row="$(awk -F '\t' -v platform="$platform_name" '$1 == platform { print; exit }' "$BASELINE")"
if [[ -z "$baseline_row" ]]; then
  echo "[platform-interface] Unknown platform baseline: $platform_name" >&2
  exit 1
fi

IFS=$'\t' read -r _ expected_target minimum_os <<< "$baseline_row"
public_modules=(InnoRouter InnoRouterInspector InnoRouterTesting)

for module in "${public_modules[@]}"; do
  interfaces=()
  while IFS= read -r interface; do
    interfaces+=("$interface")
  done < <(
    find "$derived_data/Build/Products" \
      -type f \
      -path "*/$module.swiftmodule/*.swiftinterface" \
      ! -name '*.private.swiftinterface' \
      ! -name '*.package.swiftinterface' \
      | sort
  )

  if [[ "${#interfaces[@]}" -eq 0 ]]; then
    echo "[platform-interface] $module emitted no public .swiftinterface for $platform_name" >&2
    exit 1
  fi

  for interface in "${interfaces[@]}"; do
    flags="$(grep -m 1 '^// swift-module-flags:' "$interface" || true)"
    if [[ "$flags" != *"$expected_target"* ]]; then
      echo "[platform-interface] $module target does not match $platform_name ($minimum_os): $flags" >&2
      exit 1
    fi
    if [[ "$flags" != *'-enable-library-evolution'* || "$flags" != *'-language-mode 6'* ]]; then
      echo "[platform-interface] $module is missing library evolution or Swift 6 mode: $flags" >&2
      exit 1
    fi
    if [[ "$flags" != *"-module-name $module"* ]]; then
      echo "[platform-interface] Module-name mismatch in $interface" >&2
      exit 1
    fi
  done

  echo "[platform-interface] $platform_name $module: ${#interfaces[@]} verified interface(s)"
done

umbrella="$(find "$derived_data/Build/Products" -type f \
  -path '*/InnoRouter.swiftmodule/*.swiftinterface' \
  ! -name '*.private.swiftinterface' \
  ! -name '*.package.swiftinterface' \
  | sort | head -n 1)"
for imported_module in \
  InnoRouterCore InnoRouterDeepLink InnoRouterMacros InnoRouterSwiftUI InnoRouterSystem; do
  if ! grep -Fq "@_exported import $imported_module" "$umbrella"; then
    echo "[platform-interface] Umbrella is missing @_exported import $imported_module" >&2
    exit 1
  fi
done

inspector="$(find "$derived_data/Build/Products" -type f \
  -path '*/InnoRouterInspector.swiftmodule/*.swiftinterface' \
  ! -name '*.private.swiftinterface' \
  ! -name '*.package.swiftinterface' \
  | sort | head -n 1)"
testing="$(find "$derived_data/Build/Products" -type f \
  -path '*/InnoRouterTesting.swiftmodule/*.swiftinterface' \
  ! -name '*.private.swiftinterface' \
  ! -name '*.package.swiftinterface' \
  | sort | head -n 1)"

grep -Fq 'public struct RouterInspectorImportLimits' "$inspector" || {
  echo '[platform-interface] Inspector import guardrails are missing from the public interface' >&2
  exit 1
}
grep -Fq 'final public class RouterTestStore' "$testing" || {
  echo '[platform-interface] RouterTestStore is missing from the public interface' >&2
  exit 1
}

legacy_pattern='InnoRouterEffects|InnoRouterSpatial|NavigationStore|ModalStore|FlowStore'
if grep -E "$legacy_pattern" "$umbrella" "$inspector" "$testing" >/dev/null; then
  echo '[platform-interface] A removed pre-6.0 public surface leaked into an emitted interface' >&2
  exit 1
fi

echo "[platform-interface] $platform_name public product contract passed ($minimum_os)"
