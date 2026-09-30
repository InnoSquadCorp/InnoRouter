#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="${1:-}"
PREVIEW_REF="${2:-}"
CANDIDATE_SHA="${3:-}"
if [[ -n "$CANDIDATE_SHA" ]]; then
  if ! [[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo 'Candidate source reference must be a full lowercase SHA.' >&2; exit 1
  fi
  python3 "$ROOT_DIR/scripts/release-version-policy.py" classify "$VERSION" >/dev/null
  printf '%s\n' "$CANDIDATE_SHA"
  exit 0
fi

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
