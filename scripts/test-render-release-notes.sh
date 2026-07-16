#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/render-release-notes.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased

### Fixed

- Pending pre-release fix.

## 5.1.0 - 2026-08-01

### Added

- Minor feature.

## 5.0.0 - 2026-07-17

### Breaking

- Major migration.

## 4.3.0 - 2026-06-24

### Fixed

- Historical fix.
EOF

"$SCRIPT" 5.0.0 "$TMP_DIR/CHANGELOG.md" "$TMP_DIR/5.0.0.md"
grep -q 'Migrating to InnoRouter 5' "$TMP_DIR/5.0.0.md"
grep -q 'Major migration' "$TMP_DIR/5.0.0.md"
if grep -q 'Historical fix' "$TMP_DIR/5.0.0.md"; then
  echo "[test-render-release-notes] Failed: 5.0 notes included the next release section" >&2
  exit 1
fi

"$SCRIPT" 5.1.0 "$TMP_DIR/CHANGELOG.md" "$TMP_DIR/5.1.0.md"
grep -q 'Minor feature' "$TMP_DIR/5.1.0.md"
if grep -q 'Migrating to InnoRouter' "$TMP_DIR/5.1.0.md"; then
  echo "[test-render-release-notes] Failed: minor release included a major migration link" >&2
  exit 1
fi

"$SCRIPT" 5.0.0-rc.1 "$TMP_DIR/CHANGELOG.md" "$TMP_DIR/5.0.0-rc.1.md"
grep -q 'Pre-release changes' "$TMP_DIR/5.0.0-rc.1.md"
grep -q 'Pending pre-release fix' "$TMP_DIR/5.0.0-rc.1.md"

if "$SCRIPT" 6.0.0 "$TMP_DIR/CHANGELOG.md" "$TMP_DIR/missing.md" >/dev/null 2>&1; then
  echo "[test-render-release-notes] Failed: missing release section unexpectedly passed" >&2
  exit 1
fi

echo "[test-render-release-notes] All scenarios passed"
