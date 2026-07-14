#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="${1:-}"
PREVIEW_REF="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo '[resolve-docc-source-ref] version is required' >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo '[resolve-docc-source-ref] python3 is required' >&2
  exit 1
fi

if python3 "$ROOT_DIR/scripts/release-version-policy.py" \
  classify "$VERSION" >/dev/null 2>&1; then
  printf '%s\n' "$VERSION"
elif [[ "$VERSION" == 'preview' && -n "$PREVIEW_REF" ]]; then
  printf '%s\n' "$PREVIEW_REF"
else
  printf '%s\n' 'main'
fi
