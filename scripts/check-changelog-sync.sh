#!/usr/bin/env bash
set -euo pipefail

# Verifies that any change to a `Baselines/PublicAPI/*.txt` file in
# the current branch is paired with a CHANGELOG.md change in the
# same commit range. The intent is to surface the public-API
# implications of a refactor before merge — not to police every
# style edit.
#
# Comparison range: defaults to `origin/main..HEAD`. Override with
# `BASE_REF` for fork PRs or release branches:
#   BASE_REF=origin/release/5.x ./scripts/check-changelog-sync.sh
#
# CI usage: run this after `actions/checkout@v7` with
# `fetch-depth: 0` so the base ref is reachable.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BASE_REF="${BASE_REF:-origin/main}"

if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  echo "[check-changelog-sync] Base ref '$BASE_REF' not found locally."
  echo "[check-changelog-sync] In CI, ensure actions/checkout uses fetch-depth: 0."
  exit 1
fi

CHANGED_FILES="$(git diff --name-only "$BASE_REF"...HEAD)"

if echo "$CHANGED_FILES" | grep -qE '^Baselines/PublicAPI/.*\.txt$'; then
  if echo "$CHANGED_FILES" | grep -qE '^CHANGELOG\.md$'; then
    echo "[check-changelog-sync] Baselines change paired with CHANGELOG entry — OK."
    exit 0
  fi
  echo "[check-changelog-sync] Failed: a Baselines/PublicAPI/*.txt file changed but CHANGELOG.md did not."
  echo "[check-changelog-sync]"
  echo "[check-changelog-sync] A public-API baseline change is, by definition, an"
  echo "[check-changelog-sync] observable surface change. Document it in the matching"
  echo "[check-changelog-sync] CHANGELOG release section before merging."
  echo "[check-changelog-sync]"
  echo "[check-changelog-sync] Files in the diff that triggered this check:"
  echo "$CHANGED_FILES" | grep -E '^Baselines/PublicAPI/.*\.txt$' | sed 's/^/[check-changelog-sync]   - /'
  exit 1
fi

echo "[check-changelog-sync] No Baselines/PublicAPI/*.txt changes — skipping CHANGELOG check."
