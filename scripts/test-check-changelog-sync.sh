#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/check-changelog-sync.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_scenario() {
  local name="$1"
  local change_kind="$2"
  local expected_status="$3"
  local repo_dir="$TMP_DIR/$name"
  local output_path="$TMP_DIR/$name.log"

  mkdir -p "$repo_dir/Baselines/PublicAPI" "$repo_dir/scripts"
  cp "$SOURCE_SCRIPT" "$repo_dir/scripts/check-changelog-sync.sh"
  printf '%s\n' 'public struct ExistingSymbol' >"$repo_dir/Baselines/PublicAPI/InnoRouter.txt"
  printf '%s\n' \
    '# Changelog' \
    '' \
    '## Unreleased' \
    '' \
    '### Added' \
    '' \
    '- Existing entry.' \
    '' \
    '## 5.0.0 - 2026-07-15' \
    '' \
    '- Initial release.' >"$repo_dir/CHANGELOG.md"

  (
    cd "$repo_dir"
    git init -q
    git config user.name 'InnoRouter Gate Test'
    git config user.email 'gate-test@example.invalid'
    git add .
    git commit -qm 'base'
    base_ref="$(git rev-parse HEAD)"

    case "$change_kind" in
      no-baseline)
        printf '%s\n' '# Fixture' >README.md
        ;;
      baseline-only)
        printf '%s\n' 'public struct AddedSymbol' >>Baselines/PublicAPI/InnoRouter.txt
        ;;
      historical-only)
        printf '%s\n' 'public struct AddedSymbol' >>Baselines/PublicAPI/InnoRouter.txt
        printf '%s\n' \
          '# Changelog' \
          '' \
          '## Unreleased' \
          '' \
          '### Added' \
          '' \
          '- Existing entry.' \
          '' \
          '## 5.0.0 - 2026-07-15' \
          '' \
          '- Corrected historical prose only.' >CHANGELOG.md
        ;;
      whitespace-only)
        printf '%s\n' 'public struct AddedSymbol' >>Baselines/PublicAPI/InnoRouter.txt
        printf '%s\n' \
          '# Changelog' \
          '' \
          '## Unreleased' \
          '   ' \
          '### Added' \
          '' \
          '  - Existing entry.  ' \
          '' \
          '## 5.0.0 - 2026-07-15' \
          '' \
          '- Initial release.' >CHANGELOG.md
        ;;
      missing-unreleased)
        printf '%s\n' 'public struct AddedSymbol' >>Baselines/PublicAPI/InnoRouter.txt
        printf '%s\n' \
          '# Changelog' \
          '' \
          '## 5.0.0 - 2026-07-15' \
          '' \
          '- Initial release.' >CHANGELOG.md
        ;;
      unreleased)
        printf '%s\n' 'public struct AddedSymbol' >>Baselines/PublicAPI/InnoRouter.txt
        printf '%s\n' \
          '# Changelog' \
          '' \
          '## Unreleased' \
          '' \
          '### Added' \
          '' \
          '- Existing entry.' \
          '- Added the public symbol.' \
          '' \
          '## 5.0.0 - 2026-07-15' \
          '' \
          '- Initial release.' >CHANGELOG.md
        ;;
      *)
        echo "[test-check-changelog-sync] Unknown change kind: $change_kind" >&2
        exit 1
        ;;
    esac

    git add .
    git commit -qm "$name"

    actual_status='pass'
    if ! BASE_REF="$base_ref" bash scripts/check-changelog-sync.sh >"$output_path" 2>&1; then
      actual_status='fail'
    fi

    if [[ "$actual_status" != "$expected_status" ]]; then
      echo "[test-check-changelog-sync] $name: expected $expected_status, got $actual_status" >&2
      sed 's/^/[test-check-changelog-sync]   /' "$output_path" >&2
      exit 1
    fi
  )

  echo "[test-check-changelog-sync] $name: $expected_status as expected"
}

run_scenario 'no baseline change' no-baseline pass
run_scenario 'baseline without changelog' baseline-only fail
run_scenario 'historical changelog edit' historical-only fail
run_scenario 'whitespace-only unreleased edit' whitespace-only fail
run_scenario 'missing unreleased section' missing-unreleased fail
run_scenario 'unreleased entry' unreleased pass

echo '[test-check-changelog-sync] All scenarios passed'
