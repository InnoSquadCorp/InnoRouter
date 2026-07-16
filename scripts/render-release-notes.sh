#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 <version> <changelog-path> <output-path>" >&2
  exit 2
fi

VERSION="$1"
CHANGELOG_PATH="$2"
OUTPUT_PATH="$3"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
  echo "[render-release-notes] Failed: invalid bare semantic version '$VERSION'" >&2
  exit 1
fi

if [[ ! -f "$CHANGELOG_PATH" ]]; then
  echo "[render-release-notes] Failed: changelog not found: $CHANGELOG_PATH" >&2
  exit 1
fi

SECTION_FILE="$(mktemp)"
trap 'rm -f "$SECTION_FILE"' EXIT

if [[ "$VERSION" == *-* ]]; then
  START_HEADING="## Unreleased"
  SECTION_LABEL="Pre-release changes"
else
  START_HEADING_PREFIX="## $VERSION - "
  SECTION_LABEL="Changes"
fi

LC_ALL=C awk \
  -v exact_start="${START_HEADING:-}" \
  -v start_prefix="${START_HEADING_PREFIX:-}" '
    !capturing && exact_start != "" && $0 == exact_start {
      capturing = 1
      found = 1
      next
    }
    !capturing && start_prefix != "" && index($0, start_prefix) == 1 {
      capturing = 1
      found = 1
      next
    }
    capturing && /^## / { exit }
    capturing { print }
    END { if (!found) exit 1 }
  ' "$CHANGELOG_PATH" > "$SECTION_FILE" || {
    echo "[render-release-notes] Failed: changelog section for $VERSION was not found" >&2
    exit 1
  }

if ! grep -q '^- ' "$SECTION_FILE"; then
  echo "[render-release-notes] Failed: changelog section for $VERSION has no release entries" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

{
  echo "InnoRouter $VERSION ships the validated package state from the tagged commit."
  echo
  echo "## Documentation"
  echo
  echo "- [Versioned DocC](https://innosquadcorp.github.io/InnoRouter/$VERSION/)"
  echo "- [README](https://github.com/InnoSquadCorp/InnoRouter/blob/$VERSION/README.md)"

  if [[ "$VERSION" =~ ^([0-9]+)\.0\.0($|-) ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MIGRATION_SOURCE="Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Migrating-To-InnoRouter-$MAJOR.md"
    if [[ ! -f "$ROOT_DIR/$MIGRATION_SOURCE" ]]; then
      echo "[render-release-notes] Failed: major release migration guide not found: $MIGRATION_SOURCE" >&2
      exit 1
    fi
    echo "- [Migrating to InnoRouter $MAJOR](https://innosquadcorp.github.io/InnoRouter/$VERSION/swiftui/documentation/innorouterswiftui/migrating-to-innorouter-$MAJOR/)"
  fi

  echo
  echo "## $SECTION_LABEL"
  cat "$SECTION_FILE"
} > "$OUTPUT_PATH"

echo "[render-release-notes] Wrote $OUTPUT_PATH for $VERSION"
