#!/usr/bin/env bash
set -euo pipefail

# Verifies that any change to a `Baselines/PublicAPI/*.txt` file in
# the current branch is paired with a substantive change to the
# `CHANGELOG.md` Unreleased section in the same commit range. The
# intent is to surface the public-API implications of a refactor
# before merge — not to police every style edit.
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

MERGE_BASE="$(git merge-base "$BASE_REF" HEAD)"
CHANGED_FILES="$(git diff --name-only "$MERGE_BASE" HEAD)"

extract_unreleased() {
  local changelog_path="$1"

  awk '
    /^## Unreleased[[:space:]]*$/ {
      in_unreleased = 1
      next
    }
    in_unreleased && /^## / {
      exit
    }
    in_unreleased {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line != "") {
        print line
      }
    }
  ' "$changelog_path"
}

if echo "$CHANGED_FILES" | grep -qE '^Baselines/PublicAPI/.*\.txt$'; then
  base_changelog="$(mktemp)"
  head_changelog="$(mktemp)"
  trap 'rm -f "$base_changelog" "$head_changelog"' EXIT

  if ! git show "$MERGE_BASE:CHANGELOG.md" >"$base_changelog"; then
    echo "[check-changelog-sync] Failed: CHANGELOG.md is missing at merge base $MERGE_BASE." >&2
    exit 1
  fi
  if ! git show "HEAD:CHANGELOG.md" >"$head_changelog"; then
    echo "[check-changelog-sync] Failed: CHANGELOG.md is missing at HEAD." >&2
    exit 1
  fi
  if ! grep -qE '^## Unreleased[[:space:]]*$' "$head_changelog"; then
    echo "[check-changelog-sync] Failed: CHANGELOG.md must retain an ## Unreleased section." >&2
    exit 1
  fi

  base_unreleased="$(extract_unreleased "$base_changelog")"
  head_unreleased="$(extract_unreleased "$head_changelog")"
  if [[ "$base_unreleased" != "$head_unreleased" ]]; then
    echo "[check-changelog-sync] Baselines change paired with an Unreleased entry — OK."
    exit 0
  fi
  echo "[check-changelog-sync] Failed: a Baselines/PublicAPI/*.txt file changed but"
  echo "[check-changelog-sync] CHANGELOG.md's Unreleased content did not."
  echo "[check-changelog-sync]"
  echo "[check-changelog-sync] A public-API baseline change is, by definition, an"
  echo "[check-changelog-sync] observable surface change. Document its impact and"
  echo "[check-changelog-sync] migration, when needed, under ## Unreleased before merging."
  echo "[check-changelog-sync]"
  echo "[check-changelog-sync] Files in the diff that triggered this check:"
  echo "$CHANGED_FILES" | grep -E '^Baselines/PublicAPI/.*\.txt$' | sed 's/^/[check-changelog-sync]   - /'
  exit 1
fi

echo "[check-changelog-sync] No Baselines/PublicAPI/*.txt changes — skipping CHANGELOG check."
