#!/usr/bin/env bash
set -euo pipefail

CHANGELOG_PATH="${1:-CHANGELOG.md}"

if [[ ! -f "$CHANGELOG_PATH" ]]; then
  echo "[check-changelog-phase] Failed: changelog not found: $CHANGELOG_PATH" >&2
  exit 1
fi

awk '
  /^## Unreleased[[:space:]]*$/ { unreleased += 1 }
  /^## [0-9]+\.[0-9]+\.[0-9]+ - Unreleased[[:space:]]*$/ { versioned = 1 }
  END {
    if (versioned) {
      print "[check-changelog-phase] Failed: versioned Unreleased headings conflict with the release contract" > "/dev/stderr"
      exit 1
    }
    if (unreleased != 1) {
      print "[check-changelog-phase] Failed: changelog must contain exactly one ## Unreleased heading" > "/dev/stderr"
      exit 1
    }
  }
' "$CHANGELOG_PATH"

echo "[check-changelog-phase] phase-neutral Unreleased contract passed"
