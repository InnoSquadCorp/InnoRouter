#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/resolve-docc-source-ref.sh"

assert_ref() {
  local expected="$1"
  local version="$2"
  local preview_ref="${3:-}"
  local actual

  actual="$(bash "$RESOLVER" "$version" "$preview_ref")"
  if [[ "$actual" != "$expected" ]]; then
    echo "[test-resolve-docc-source-ref] $version: expected $expected, got $actual" >&2
    exit 1
  fi
  echo "[test-resolve-docc-source-ref] $version -> $actual"
}

assert_ref '5.0.0' '5.0.0'
assert_ref '5.0.0-rc.1' '5.0.0-rc.1'
assert_ref '5.1.0-beta.2' '5.1.0-beta.2'
assert_ref '0123456789abcdef' 'preview' '0123456789abcdef'
assert_ref 'main' 'preview'
assert_ref 'main' 'nightly' 'ignored-preview-ref'
assert_ref 'main' '5.0.0-alpha.1'
assert_ref 'main' '05.0.0'
assert_ref 'main' '5.0.0-rc.01'

if bash "$RESOLVER" >/dev/null 2>&1; then
  echo '[test-resolve-docc-source-ref] missing version unexpectedly succeeded' >&2
  exit 1
fi

echo '[test-resolve-docc-source-ref] All scenarios passed'
