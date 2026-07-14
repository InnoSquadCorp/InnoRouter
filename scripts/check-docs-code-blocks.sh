#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "[check-docs-code-blocks] Failed: ripgrep (rg) is required but was not found in PATH" >&2
  exit 1
fi

DOC_FILES=()
while IFS= read -r file_path; do
  DOC_FILES+=("$file_path")
done < <(rg --files -g '*.md' | sort)

mkdir -p "$ROOT_DIR/.build/doc-snippet-check" "$ROOT_DIR/.build/doc-snippet-module-cache"
TMP_DIR="$(mktemp -d "$ROOT_DIR/.build/doc-snippets.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/Sources/DocSnippetCompile"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/doc-snippet-module-cache"

cat >"$TMP_DIR/Package.swift" <<EOF
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "InnoRouterDocSnippets",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    dependencies: [
        .package(path: "$ROOT_DIR")
    ],
    targets: [
        .executableTarget(
            name: "DocSnippetCompile",
            dependencies: [
                .product(name: "InnoRouter", package: "InnoRouter"),
                .product(name: "InnoRouterCore", package: "InnoRouter"),
                .product(name: "InnoRouterSwiftUI", package: "InnoRouter"),
                .product(name: "InnoRouterSpatial", package: "InnoRouter"),
                .product(name: "InnoRouterDeepLink", package: "InnoRouter"),
                .product(name: "InnoRouterEffects", package: "InnoRouter"),
                .product(name: "InnoRouterMacros", package: "InnoRouter"),
                .product(name: "InnoRouterTesting", package: "InnoRouter")
            ]
        )
    ]
)
EOF

failures=0
compile_count=0
snippet_count=0

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

record_failure() {
  echo "[check-docs-code-blocks] Failed: $1" >&2
  failures=1
}

write_compile_snippet() {
  local source_file="$1"
  local start_line="$2"
  local body="$3"

  snippet_count=$((snippet_count + 1))
  local snippet_file="$TMP_DIR/Sources/DocSnippetCompile/main.swift"
  cat >"$snippet_file" <<EOF
import Foundation
import SwiftUI

// Source: $source_file:$start_line
$body
EOF

  echo "[check-docs-code-blocks] Typechecking $source_file:$start_line"
  local build_log="$TMP_DIR/snippet-build.log"
  if swift build --package-path "$TMP_DIR" --scratch-path "$ROOT_DIR/.build/doc-snippet-check" --target DocSnippetCompile >"$build_log" 2>&1; then
    compile_count=$((compile_count + 1))
  else
    sed 's/^/[check-docs-code-blocks]   /' "$build_log" >&2
    record_failure "$source_file:$start_line compile snippet failed"
  fi
}

for file_path in "${DOC_FILES[@]}"; do
  in_swift_block=0
  block_mode=""
  block_start_line=0
  block_body=""
  line_number=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    if [[ "$in_swift_block" -eq 0 ]]; then
      if [[ "$line" =~ ^[[:space:]]{0,3}\`\`\`swift($|[[:space:]]+(.*)$) ]]; then
        info="$(trim "${BASH_REMATCH[2]:-}")"
        block_start_line="$line_number"
        block_body=""

        if [[ "$info" == "compile" ]]; then
          block_mode="compile"
        elif [[ "$info" =~ ^skip[[:space:]]+(.+)$ ]]; then
          reason="${BASH_REMATCH[1]}"
          if [[ -z "$(trim "$reason")" ]]; then
            record_failure "$file_path:$line_number uses 'swift skip' without a reason"
          fi
          block_mode="skip"
        elif [[ "$info" == "skip" ]]; then
          record_failure "$file_path:$line_number uses 'swift skip' without a reason"
          block_mode="skip"
        else
          record_failure "$file_path:$line_number Swift fence must be annotated as 'swift compile' or 'swift skip <reason>'"
          block_mode="skip"
        fi

        in_swift_block=1
      fi
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]{0,3}\`\`\`[[:space:]]*$ ]]; then
      if [[ "$block_mode" == "compile" ]]; then
        write_compile_snippet "$file_path" "$block_start_line" "$block_body"
      fi
      in_swift_block=0
      block_mode=""
      block_body=""
      continue
    fi

    block_body+="$line"$'\n'
  done <"$file_path"

  if [[ "$in_swift_block" -ne 0 ]]; then
    record_failure "$file_path:$block_start_line has an unterminated Swift fence"
  fi
done

if [[ "$compile_count" -eq 0 ]]; then
  record_failure "no 'swift compile' documentation snippets were found"
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "[check-docs-code-blocks] Swift fences annotated; $compile_count compile snippet(s) typechecked"
