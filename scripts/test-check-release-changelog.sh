#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/check-release-changelog.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-release-changelog.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

write_fixture() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"$TEMP_DIR/$name.md"
}

expect_pass() {
  local name="$1"
  local version="$2"
  local channel="$3"

  if ! bash "$SUBJECT" "$version" "$channel" "$TEMP_DIR/$name.md" >/dev/null; then
    echo "[test-check-release-changelog] $name: expected pass" >&2
    exit 1
  fi
  echo "[test-check-release-changelog] $name: passed"
}

expect_fail() {
  local name="$1"
  local version="$2"
  local channel="$3"

  if bash "$SUBJECT" "$version" "$channel" "$TEMP_DIR/$name.md" >/dev/null 2>&1; then
    echo "[test-check-release-changelog] $name: expected failure" >&2
    exit 1
  fi
  echo "[test-check-release-changelog] $name: failed as expected"
}

write_fixture ga-valid \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '### Added' '' \
  '- Stable release.' '' \
  '## 4.3.0 - 2026-06-01' '' \
  '- Previous release.'

write_fixture prerelease-valid \
  '# Changelog' '' \
  '## Unreleased' '' \
  '### Changed' '' \
  '- Release candidate notes.' '' \
  '## 4.3.0 - 2026-06-01' '' \
  '- Previous release.'

write_fixture missing-unreleased \
  '# Changelog' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '- Stable release.'

write_fixture missing-version \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 4.3.0 - 2026-06-01' '' \
  '- Previous release.'

write_fixture empty-version \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '### Added' '' \
  '## 4.3.0 - 2026-06-01' '' \
  '- Previous release.'

write_fixture wrong-order \
  '# Changelog' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '- Stable release.' '' \
  '## Unreleased'

write_fixture invalid-date \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 5.0.0 - 2026-02-30' '' \
  '- Stable release.'

write_fixture empty-prerelease \
  '# Changelog' '' \
  '## Unreleased' '' \
  '### Changed' '' \
  '## 4.3.0 - 2026-06-01' '' \
  '- Previous release.'

write_fixture nonempty-unreleased \
  '# Changelog' '' \
  '## Unreleased' '' \
  '### Changed' '' \
  '- This note was not moved.' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '- Stable release.'

write_fixture stale-target-not-first \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 5.1.0 - 2026-07-15' '' \
  '- Newer release.' '' \
  '## 5.0.0 - 2026-07-14' '' \
  '- Stale release.'

write_fixture duplicate-version \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '- Stable release.' '' \
  '## 5.0.0 - 2026-07-14' '' \
  '- Duplicate release.'

write_fixture duplicate-unreleased \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## Unreleased' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '- Stable release.'

write_fixture prerelease-after-ga \
  '# Changelog' '' \
  '## Unreleased' '' \
  '- Release candidate notes.' '' \
  '## 5.0.0 - 2026-07-15' '' \
  '- Stable release.'

write_fixture prerelease-unreleased-after-release \
  '# Changelog' '' \
  '## 4.3.0 - 2026-06-01' '' \
  '- Previous release.' '' \
  '## Unreleased' '' \
  '- Release candidate notes.'

expect_pass ga-valid 5.0.0 ga
expect_pass prerelease-valid 5.0.0-rc.1 prerelease
expect_fail missing-unreleased 5.0.0 ga
expect_fail missing-version 5.0.0 ga
expect_fail empty-version 5.0.0 ga
expect_fail wrong-order 5.0.0 ga
expect_fail invalid-date 5.0.0 ga
expect_fail empty-prerelease 5.0.0-rc.1 prerelease
expect_fail nonempty-unreleased 5.0.0 ga
expect_fail stale-target-not-first 5.0.0 ga
expect_fail duplicate-version 5.0.0 ga
expect_fail duplicate-unreleased 5.0.0 ga
expect_fail prerelease-after-ga 5.0.0-rc.1 prerelease
expect_fail prerelease-unreleased-after-release 5.0.0-rc.1 prerelease

echo '[test-check-release-changelog] All scenarios passed'
