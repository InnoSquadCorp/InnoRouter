#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
PREVIEW_REF="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo '[resolve-docc-source-ref] version is required' >&2
  exit 1
fi

if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta)\.[0-9]+)?$ ]]; then
  printf '%s\n' "$VERSION"
elif [[ "$VERSION" == 'preview' && -n "$PREVIEW_REF" ]]; then
  printf '%s\n' "$PREVIEW_REF"
else
  printf '%s\n' 'main'
fi
