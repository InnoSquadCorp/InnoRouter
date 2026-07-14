#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/release-version-policy.py"

expect_output() {
  local name="$1"
  local expected="$2"
  local input="$3"
  shift 3

  local output
  if ! output="$(printf '%s' "$input" | "$SUBJECT" "$@" 2>&1)"; then
    echo "[test-release-version-policy] $name: expected success" >&2
    printf '%s\n' "$output" | sed 's/^/[test-release-version-policy]   /' >&2
    exit 1
  fi

  if [[ "$output" != "$expected" ]]; then
    echo "[test-release-version-policy] $name: output mismatch" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
    exit 1
  fi

  echo "[test-release-version-policy] $name: passed"
}

expect_failure() {
  local name="$1"
  local input="$2"
  shift 2

  if printf '%s' "$input" | "$SUBJECT" "$@" >/dev/null 2>&1; then
    echo "[test-release-version-policy] $name: expected failure" >&2
    exit 1
  fi

  echo "[test-release-version-policy] $name: failed as expected"
}

expect_output 'classifies GA' 'ga' '' classify 5.0.0
expect_output 'classifies release candidate' 'prerelease' '' classify 5.0.0-rc.10
expect_output 'classifies beta' 'prerelease' '' classify 0.0.0-beta.0

expect_failure 'rejects leading v' '' classify v5.0.0
expect_failure 'rejects leading-zero major' '' classify 05.0.0
expect_failure 'rejects leading-zero minor' '' classify 5.00.0
expect_failure 'rejects leading-zero patch' '' classify 5.0.01
expect_failure 'rejects leading-zero ordinal' '' classify 5.0.0-rc.01
expect_failure 'rejects unsupported alpha channel' '' classify 5.0.0-alpha.1
expect_failure 'rejects build metadata' '' classify 5.0.0+build.1
expect_failure 'rejects missing prerelease ordinal' '' classify 5.0.0-rc

published_input=$'4.9.99\n5.0.0-beta.2\nlatest\n5.0.0-rc.2\n5.0.1-beta.1\nv6.0.0\n5.0.0\n5.0.0-beta.10\nindex.html\n5.0.0-rc.10\n4.10.0\n05.0.0\n 6.0.0\n'
published_expected=$'5.0.1-beta.1\n5.0.0\n5.0.0-rc.10\n5.0.0-rc.2\n5.0.0-beta.10\n5.0.0-beta.2\n4.10.0\n4.9.99'
expect_output \
  'sorts supported versions by SemVer precedence' \
  "$published_expected" \
  "$published_input" \
  sort-published

expect_output 'updates latest when no versions exist' 'update 5.0.0' '' latest-action 5.0.0
expect_output \
  'preserves a higher GA' \
  'preserve 5.1.0' \
  $'5.1.0\n5.2.0-rc.1\nlatest\n' \
  latest-action 5.0.0
expect_output \
  'updates latest for an equal GA rebuild' \
  'update 5.1.0' \
  $'5.1.0\n5.0.0\n' \
  latest-action 5.1.0
expect_output \
  'updates latest for a higher GA' \
  'update 5.2.0' \
  $'5.1.0\n4.10.0\n' \
  latest-action 5.2.0
expect_output \
  'ignores prerelease-only published versions for latest' \
  'update 5.0.0' \
  $'5.1.0-rc.10\n5.0.0-beta.2\n' \
  latest-action 5.0.0

expect_failure 'rejects prerelease latest candidate' '' latest-action 5.0.0-rc.1
expect_failure 'rejects invalid latest candidate' '' latest-action 05.0.0

echo '[test-release-version-policy] All scenarios passed'
