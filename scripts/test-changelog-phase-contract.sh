#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-changelog-phase.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

write_fixture() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"$TEMP_DIR/$name.md"
}

check_sync_fixture() {
  local name="$1"
  local expected="$2"
  local repo_dir="$TEMP_DIR/repo-$name"

  mkdir -p "$repo_dir/Baselines/PublicAPI" "$repo_dir/scripts"
  cp "$ROOT_DIR/scripts/check-changelog-sync.sh" "$repo_dir/scripts/"
  cp "$ROOT_DIR/scripts/check-changelog-phase.sh" "$repo_dir/scripts/"
  printf '%s\n' 'public struct ExistingSymbol' >"$repo_dir/Baselines/PublicAPI/InnoRouter.txt"
  printf '%s\n' \
    '# Changelog' '' \
    '## Unreleased' '' \
    '### Breaking' '' \
    '- Existing draft note.' '' \
    '## 5.2.1 - 2026-08-01' '' \
    '- Previous release.' >"$repo_dir/CHANGELOG.md"

  (
    cd "$repo_dir"
    git init -q
    git config user.name 'InnoRouter Gate Test'
    git config user.email 'gate-test@example.invalid'
    git add .
    git commit -qm 'base'
    base_ref="$(git rev-parse HEAD)"

    cp "$TEMP_DIR/$name.md" CHANGELOG.md
    printf '%s\n' 'public struct AddedSymbol' >>Baselines/PublicAPI/InnoRouter.txt
    git add CHANGELOG.md Baselines/PublicAPI/InnoRouter.txt
    git commit -qm "$name"

    actual=pass
    if ! BASE_REF="$base_ref" bash scripts/check-changelog-sync.sh >/dev/null 2>&1; then
      actual=fail
    fi
    [[ "$actual" == "$expected" ]]
  )
}

expect_shared_pass() {
  local name="$1"
  local version="$2"
  local channel="$3"
  local fixture="$TEMP_DIR/$name.md"

  bash "$ROOT_DIR/scripts/check-changelog-phase.sh" "$fixture" >/dev/null
  bash "$ROOT_DIR/scripts/check-release-changelog.sh" \
    "$version" "$channel" "$fixture" >/dev/null
  check_sync_fixture "$name" pass
  echo "[test-changelog-phase-contract] $name passed every changelog gate"
}

write_fixture prerelease \
  '# Changelog' '' \
  '## Unreleased' '' \
  '### Breaking' '' \
  '- Macro-first release candidate.' '' \
  '## 5.2.1 - 2026-08-01' '' \
  '- Previous release.'

write_fixture ga \
  '# Changelog' '' \
  '## Unreleased' '' \
  '## 6.0.0 - 2026-09-08' '' \
  '### Breaking' '' \
  '- Macro-first stable release.' '' \
  '## 5.2.1 - 2026-08-01' '' \
  '- Previous release.'

write_fixture versioned-unreleased \
  '# Changelog' '' \
  '## 6.0.0 - Unreleased' '' \
  '### Breaking' '' \
  '- Conflicting heading.'

write_fixture duplicate-unreleased \
  '# Changelog' '' \
  '## Unreleased' '' \
  '- First.' '' \
  '## Unreleased' '' \
  '- Second.'

expect_phase_failure() {
  local fixture="$1"
  local message="$2"
  local log="$TEMP_DIR/phase-failure.log"

  if bash "$ROOT_DIR/scripts/check-changelog-phase.sh" "$fixture" >"$log" 2>&1; then
    echo "[test-changelog-phase-contract] invalid fixture passed unexpectedly: $fixture" >&2
    exit 1
  fi
  if ! grep -F -- "$message" "$log" >/dev/null; then
    echo "[test-changelog-phase-contract] fixture failed for an unexpected reason: $fixture" >&2
    sed 's/^/[test-changelog-phase-contract]   /' "$log" >&2
    exit 1
  fi
}

expect_shared_pass prerelease 6.0.0-rc.1 prerelease
expect_shared_pass ga 6.0.0 ga

expect_phase_failure \
  "$TEMP_DIR/versioned-unreleased.md" \
  'versioned Unreleased headings conflict with the release contract'
expect_phase_failure \
  "$TEMP_DIR/duplicate-unreleased.md" \
  'changelog must contain exactly one ## Unreleased heading'
if bash "$ROOT_DIR/scripts/check-release-changelog.sh" \
  6.0.0-rc.1 prerelease "$TEMP_DIR/versioned-unreleased.md" >/dev/null 2>&1; then
  echo '[test-changelog-phase-contract] versioned Unreleased passed release check unexpectedly' >&2
  exit 1
fi
check_sync_fixture versioned-unreleased fail

echo '[test-changelog-phase-contract] All scenarios passed'
