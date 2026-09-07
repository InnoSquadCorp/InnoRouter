#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_DIR="$ROOT_DIR/Baselines/PublicAPI"
MODE="check"

usage() {
  cat <<'EOF'
Usage: ./scripts/check-public-api.sh [--write-baseline]

Extracts public symbol graphs for every public library product, normalizes
them into a stable text baseline, and compares the result against
Baselines/PublicAPI.

Regenerate baselines only with the same Swift 6.3 toolchain used by CI so
symbol graph output stays comparable.

Options:
  --write-baseline   Regenerate committed baselines instead of checking them.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write-baseline)
      MODE="write"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[check-public-api] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

for required in swift xcrun python3 diff xcodebuild; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "[check-public-api] $required is required" >&2
    exit 1
  fi
done

canonicalize_path() {
  python3 - "$1" <<'PY'
from __future__ import annotations

import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

print_toolchain_context() {
  local swift_path
  local xcrun_swift_path
  local xcodebuild_path
  local selected_xcode
  local swift_version_output
  local xcrun_swift_version_output

  swift_path="$(canonicalize_path "$(command -v swift)")"
  xcrun_swift_path="$(canonicalize_path "$(xcrun -f swift)")"
  xcodebuild_path="$(canonicalize_path "$(xcrun -f xcodebuild)")"
  selected_xcode="$(xcode-select -p)"
  swift_version_output="$(swift --version)"
  xcrun_swift_version_output="$(xcrun swift --version)"

  echo "[check-public-api] Active toolchain"
  echo "[check-public-api] xcode-select: $selected_xcode"
  echo "[check-public-api] swift: $swift_path"
  printf '%s\n' "$swift_version_output" | sed 's/^/[check-public-api] /'
  echo "[check-public-api] xcrun swift: $xcrun_swift_path"
  printf '%s\n' "$xcrun_swift_version_output" | sed 's/^/[check-public-api] /'
  echo "[check-public-api] xcodebuild: $xcodebuild_path"
  xcodebuild -version | sed 's/^/[check-public-api] /'

  if [[ "$swift_version_output" != "$xcrun_swift_version_output" ]]; then
    echo "[check-public-api] Toolchain mismatch: swift on PATH reports a different toolchain than xcrun swift." >&2
    echo "[check-public-api] Ensure swift, xcrun, and xcodebuild all come from the same Xcode installation." >&2
    exit 1
  fi
}

cd "$ROOT_DIR"
ROOT_DIR_CANONICAL="$(cd "$ROOT_DIR" && pwd -P)"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-public-api.XXXXXX")"
cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

products_file="$temp_root/products.tsv"

python3 - <<'PY' >"$products_file"
from __future__ import annotations

import json
import subprocess
import sys

package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))

for product in package["products"]:
    product_type = product.get("type") or {}
    if not (isinstance(product_type, dict) and "library" in product_type):
        continue

    targets = product.get("targets", [])
    if len(targets) != 1:
        print(
            f"[check-public-api] Expected single-target library product for {product['name']}, got {targets}",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"{product['name']}\t{targets[0]}")
PY

check_sendable_contracts() {
  local root="$1"

  python3 - "$root" <<'PY'
from __future__ import annotations

import pathlib
import sys

root = pathlib.Path(sys.argv[1])

checks = [
    (
        "Sources/InnoRouterDeepLink/RouterLinkPipeline.swift",
        [
            "shouldRequireAuthentication: @Sendable (R) -> Bool",
            "isAuthenticated: @Sendable () async -> Bool",
            "public typealias Planner = @Sendable (R) -> RouterPlan<R>",
            "customResolver: @escaping @Sendable (URL) -> RouterPlan<R>?",
        ],
    ),
    (
        "Sources/InnoRouterDeepLink/DeepLink.swift",
        [
            "handler: @escaping @Sendable (DeepLinkParameters) -> Output?",
        ],
    ),
    (
        "Sources/InnoRouterSwiftUI/RouterStoreTypes.swift",
        [
            "prepare: @escaping @MainActor @Sendable (RouterTransition<R>) async -> RouterPolicyDecision",
            "public var onEvent: (@MainActor @Sendable (RouterEvent<R>) -> Void)?",
        ],
    ),
]

missing: list[str] = []
for rel_path, patterns in checks:
    file_path = root / rel_path
    if not file_path.exists():
        missing.append(f"{rel_path}: missing file")
        continue
    content = file_path.read_text()
    for pattern in patterns:
        if pattern not in content:
            missing.append(f"{rel_path}: missing `{pattern}`")

if missing:
    print("[check-public-api] Missing source-level @Sendable contracts:", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
PY
}

read_target_context() {
  local target_triple_arg="${1:-}"

  if [[ -n "$target_triple_arg" ]]; then
    swift -print-target-info -target "$target_triple_arg" | python3 -c '
import json, sys

info = json.load(sys.stdin)
print("{}\t{}".format(info["target"]["triple"], info["paths"]["runtimeResourcePath"]))
'
    return
  fi

  swift -print-target-info | python3 -c '
import json, sys

info = json.load(sys.stdin)
print("{}\t{}".format(info["target"]["triple"], info["paths"]["runtimeResourcePath"]))
'
}

resolve_platform_frameworks_dir() {
  local sdk_name="${1:-}"
  local sdk_platform_path=""

  if [[ -n "$sdk_name" ]]; then
    sdk_platform_path="$(xcrun --sdk "$sdk_name" --show-sdk-platform-path 2>/dev/null || true)"
  else
    sdk_platform_path="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
  fi

  if [[ -z "$sdk_platform_path" ]]; then
    return
  fi

  local candidate_platform_frameworks_dir="$sdk_platform_path/Developer/Library/Frameworks"
  if [[ -d "$candidate_platform_frameworks_dir" ]]; then
    printf '%s\n' "$candidate_platform_frameworks_dir"
  fi
}

print_toolchain_context

echo "[check-public-api] Building package for symbol extraction"
swift build >/dev/null

echo "[check-public-api] Verifying source-level @Sendable contracts"
check_sendable_contracts "$ROOT_DIR"

HOST_BUILD_BIN_DIR="$(swift build --show-bin-path)"
HOST_MODULES_DIR="$HOST_BUILD_BIN_DIR/Modules"
HOST_MODULE_CACHE_DIR="$HOST_BUILD_BIN_DIR/ModuleCache"
if [[ ! -d "$HOST_MODULES_DIR" ]] \
  && find "$HOST_BUILD_BIN_DIR" -maxdepth 1 -type d -name '*.swiftmodule' -print -quit \
    | grep -q .; then
  # Xcode 27's native SwiftPM build layout places module directories directly
  # in Products/Debug and the module cache beside Products.
  HOST_MODULES_DIR="$HOST_BUILD_BIN_DIR"
  HOST_MODULE_CACHE_DIR="$(cd "$HOST_BUILD_BIN_DIR/../.." && pwd -P)/ModuleCache.noindex"
fi
HOST_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
HOST_PLATFORM_FRAMEWORKS_DIR="$(resolve_platform_frameworks_dir)"
IFS=$'\t' read -r HOST_TARGET_TRIPLE HOST_RESOURCE_DIR <<< "$(read_target_context)"

[[ -d "$HOST_MODULES_DIR" ]] || { echo "[check-public-api] Missing modules directory: $HOST_MODULES_DIR" >&2; exit 1; }
[[ -d "$HOST_MODULE_CACHE_DIR" ]] || { echo "[check-public-api] Missing module cache directory: $HOST_MODULE_CACHE_DIR" >&2; exit 1; }
[[ -n "$HOST_SDK_PATH" ]] || { echo "[check-public-api] Failed to locate host SDK path" >&2; exit 1; }

toolchain_bin_dir="$(cd "$(dirname "$(dirname "$HOST_RESOURCE_DIR")")/bin" && pwd -P)"
swift_symbolgraph_extract_bin="$toolchain_bin_dir/swift-symbolgraph-extract"

[[ -x "$swift_symbolgraph_extract_bin" ]] || {
  echo "[check-public-api] Failed to locate swift-symbolgraph-extract at $swift_symbolgraph_extract_bin" >&2
  exit 1
}

normalize_symbol_graph() {
  local product_name="$1"
  local raw_dir="$2"
  local output_path="$3"
  local repo_root="$4"

  python3 - "$product_name" "$raw_dir" "$output_path" "$repo_root" <<'PY'
from __future__ import annotations

import json
import pathlib
import re
import sys
import urllib.parse

product_name, raw_dir, output_path, repo_root = sys.argv[1:]
repo_root = pathlib.Path(repo_root).resolve()
rows = set()
kept_symbols = {}

def normalize_text(value: str) -> str:
    return " ".join(value.split())

def normalize_declaration(value: str) -> str:
    # Swift 6.2.1 and 6.3 disagree on whether public symbol graphs retain
    # closure-level @Sendable in declaration fragments. Keep the baseline
    # stable here and enforce @Sendable separately against source above.
    value = re.sub(r"(?<!\w)@Sendable\b\s*", "", value)
    return normalize_text(value)

def repo_source_path(symbol: dict) -> pathlib.Path | None:
    precise = symbol.get("identifier", {}).get("precise", "")
    if "::SYNTHESIZED::" in precise:
        return None

    location = symbol.get("location") or {}
    uri = location.get("uri")
    if not uri:
        return None

    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "file":
        return None

    path = pathlib.Path(urllib.parse.unquote(parsed.path)).resolve()
    try:
        path.relative_to(repo_root)
    except ValueError:
        return None
    return path

symbol_graph_paths = sorted(pathlib.Path(raw_dir).rglob("*.symbols.json"))

for symbol_graph_path in symbol_graph_paths:
    document = json.loads(symbol_graph_path.read_text())
    for symbol in document.get("symbols", []):
        if repo_source_path(symbol) is None:
            continue

        precise = symbol.get("identifier", {}).get("precise", "")
        if not precise:
            continue

        path_components = symbol.get("pathComponents") or []
        path = ".".join(path_components) if path_components else symbol.get("names", {}).get("title", "")
        title = symbol.get("names", {}).get("title", "")
        kept_symbols[precise] = path or title

for symbol_graph_path in symbol_graph_paths:
    document = json.loads(symbol_graph_path.read_text())
    for symbol in document.get("symbols", []):
        if repo_source_path(symbol) is None:
            continue

        precise = symbol.get("identifier", {}).get("precise", "")
        kind = symbol.get("kind", {}).get("identifier", "")
        path_components = symbol.get("pathComponents") or []
        path = ".".join(path_components) if path_components else symbol.get("names", {}).get("title", "")
        title = symbol.get("names", {}).get("title", "")
        declaration = "".join(fragment.get("spelling", "") for fragment in symbol.get("declarationFragments", []))
        declaration = normalize_declaration(declaration)
        if not declaration:
            declaration = title
        availability = normalize_text(
            json.dumps(symbol.get("availability", []), sort_keys=True, separators=(",", ":"))
        )
        rows.add(("symbol", kind, path, title, declaration, availability))

    for relationship in document.get("relationships", []):
        source = relationship.get("source", "")
        target = relationship.get("target", "")
        if source not in kept_symbols or target not in kept_symbols:
            continue

        rows.add((
            "relationship",
            relationship.get("kind", ""),
            kept_symbols[source],
            kept_symbols[target],
            "",
            "",
        ))

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(f"# Public API baseline for {product_name}\n")
    for row in sorted(rows):
        handle.write(" | ".join(row).rstrip() + "\n")
PY
}

extract_product_symbols() {
  local target_name="$1"
  local output_dir="$2"
  local modules_dir="$3"
  local module_cache_dir="$4"
  local sdk_path="$5"
  local target_triple="$6"
  local resource_dir="$7"
  shift 7

  local -a framework_search_args=()
  while [[ $# -gt 0 ]]; do
    if [[ -n "$1" ]]; then
      framework_search_args+=(-F "$1")
    fi
    shift
  done

  rm -rf "$output_dir"
  mkdir -p "$output_dir"

  "$swift_symbolgraph_extract_bin" \
    -module-name "$target_name" \
    -I "$modules_dir" \
    "${framework_search_args[@]}" \
    -target "$target_triple" \
    -module-cache-path "$module_cache_dir" \
    -sdk "$sdk_path" \
    -resource-dir "$resource_dir" \
    -minimum-access-level public \
    -omit-extension-block-symbols \
    -output-dir "$output_dir" >/dev/null

  [[ -f "$output_dir/${target_name}.symbols.json" ]] || {
    echo "[check-public-api] Failed to generate symbol graph for $target_name" >&2
    exit 1
  }
}

mkdir -p "$BASELINE_DIR"
if [[ "$MODE" == "write" ]]; then
  find "$BASELINE_DIR" -maxdepth 1 -type f -name '*.txt' -delete
fi

expected_files=()
failed=0

while IFS=$'\t' read -r product_name target_name; do
  [[ -n "$product_name" && -n "$target_name" ]] || continue

  expected_files+=("${product_name}.txt")

  raw_dir="$temp_root/raw/$product_name"
  normalized_path="$temp_root/normalized/${product_name}.txt"

  echo "[check-public-api] Extracting $product_name ($target_name)"
  extract_product_symbols \
    "$target_name" \
    "$raw_dir/host" \
    "$HOST_MODULES_DIR" \
    "$HOST_MODULE_CACHE_DIR" \
    "$HOST_SDK_PATH" \
    "$HOST_TARGET_TRIPLE" \
    "$HOST_RESOURCE_DIR" \
    "$HOST_PLATFORM_FRAMEWORKS_DIR"

  if [[ "$product_name" == "InnoRouter" ]]; then
    # The umbrella intentionally declares no duplicate wrappers. Its public
    # contract is the union of the canonical modules it re-exports; package
    # access hides the 5.x compatibility implementation from these graphs.
    for canonical_module in InnoRouterCore InnoRouterDeepLink InnoRouterSwiftUI InnoRouterMacros InnoRouterSystem; do
      extract_product_symbols \
        "$canonical_module" \
        "$raw_dir/$canonical_module" \
        "$HOST_MODULES_DIR" \
        "$HOST_MODULE_CACHE_DIR" \
        "$HOST_SDK_PATH" \
        "$HOST_TARGET_TRIPLE" \
        "$HOST_RESOURCE_DIR" \
        "$HOST_PLATFORM_FRAMEWORKS_DIR"
    done
  fi

  mkdir -p "$(dirname "$normalized_path")"
  normalize_symbol_graph "$product_name" "$raw_dir" "$normalized_path" "$ROOT_DIR_CANONICAL"

  if [[ "$product_name" == "InnoRouter" ]]; then
    retired_surface='(^|[^[:alnum:]_])(NavigationStore|ModalStore|FlowStore|AppShellStore|AdaptiveSplitStore|SceneStore|NavigationIntent|ModalIntent|FlowIntent|NavigationPlan|FlowPlan|AsyncNavigationMiddlewareExecutor|ChildCoordinator)([^[:alnum:]_]|$)'
    if grep -E -- "$retired_surface" "$normalized_path" >/dev/null 2>&1; then
      echo "[check-public-api] Retired 5.x surface leaked into InnoRouter 6:" >&2
      grep -En -- "$retired_surface" "$normalized_path" >&2
      failed=1
    fi
  fi

  baseline_path="$BASELINE_DIR/${product_name}.txt"
  if [[ "$MODE" == "write" ]]; then
    cp "$normalized_path" "$baseline_path"
    continue
  fi

  if [[ ! -f "$baseline_path" ]]; then
    echo "[check-public-api] Missing baseline: $baseline_path" >&2
    failed=1
    continue
  fi

  if ! diff -u "$baseline_path" "$normalized_path"; then
    echo "[check-public-api] Public API drift detected for $product_name" >&2
    failed=1
  fi
done <"$products_file"

if [[ "$MODE" == "check" ]]; then
  shopt -s nullglob
  for baseline_path in "$BASELINE_DIR"/*.txt; do
    baseline_name="$(basename "$baseline_path")"
    keep=0
    for expected_name in "${expected_files[@]}"; do
      if [[ "$baseline_name" == "$expected_name" ]]; then
        keep=1
        break
      fi
    done
    if [[ "$keep" -eq 0 ]]; then
      echo "[check-public-api] Stale baseline present: $baseline_name" >&2
      failed=1
    fi
  done
  shopt -u nullglob
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

bash "$ROOT_DIR/scripts/check-public-api-budget.sh" "$BASELINE_DIR"

if [[ "$MODE" == "write" ]]; then
  echo "[check-public-api] Baselines regenerated in $BASELINE_DIR"
else
  echo "[check-public-api] Public API baselines match"
fi
