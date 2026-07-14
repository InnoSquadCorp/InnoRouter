#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/resolve-release-metadata.sh"

expect_success() {
  local name="$1"
  local expected="$2"
  shift 2

  local output
  if ! output="$(bash "$SUBJECT" "$@" 2>&1)"; then
    echo "[test-resolve-release-metadata] $name: expected success" >&2
    printf '%s\n' "$output" | sed 's/^/[test-resolve-release-metadata]   /' >&2
    exit 1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -Fqx -- "$line" <<<"$output"; then
      echo "[test-resolve-release-metadata] $name: missing '$line'" >&2
      printf '%s\n' "$output" | sed 's/^/[test-resolve-release-metadata]   /' >&2
      exit 1
    fi
  done <<<"$expected"

  echo "[test-resolve-release-metadata] $name: passed"
}

expect_failure() {
  local name="$1"
  shift

  if bash "$SUBJECT" "$@" >/dev/null 2>&1; then
    echo "[test-resolve-release-metadata] $name: expected failure" >&2
    exit 1
  fi

  echo "[test-resolve-release-metadata] $name: failed as expected"
}

expect_success \
  'GA tag push publishes' \
  $'version=5.0.0\nrelease_ref=refs/tags/5.0.0\npublish=true\nprerelease=false\nupdate_latest=true' \
  push 5.0.0 false

expect_success \
  'manual GA publishes' \
  $'publish=true\nprerelease=false\nupdate_latest=true' \
  workflow_dispatch 5.1.0 false

expect_success \
  'manual release candidate publishes without latest' \
  $'publish=true\nprerelease=true\nupdate_latest=false' \
  workflow_dispatch 5.0.0-rc.1 true

expect_success \
  'prerelease tag push is a no-op' \
  $'publish=false\nprerelease=true\nupdate_latest=false' \
  push 5.0.0-beta.2 false

expect_failure 'manual prerelease requires flag' workflow_dispatch 5.0.0-rc.1 false
expect_failure 'manual GA rejects prerelease flag' workflow_dispatch 5.0.0 true
expect_failure 'leading v is rejected' push v5.0.0 false
expect_failure 'leading zero is rejected' push 05.0.0 false
expect_failure 'leading-zero minor is rejected' push 5.00.0 false
expect_failure 'leading-zero patch is rejected' push 5.0.00 false
expect_failure 'leading-zero prerelease ordinal is rejected' workflow_dispatch 5.0.0-rc.01 true
expect_failure 'unsupported prerelease channel is rejected' workflow_dispatch 5.0.0-alpha.1 true
expect_failure 'build metadata is rejected' workflow_dispatch 5.0.0+build.1 false
expect_failure 'whitespace is rejected' workflow_dispatch ' 5.0.0' false
expect_failure 'newlines are rejected' workflow_dispatch $'5.0.0\nowned' false
expect_failure 'shell metacharacters are rejected' workflow_dispatch '5.0.0;echo-owned' false
# shellcheck disable=SC2016 # The command substitution must remain literal test input.
expect_failure 'command substitution text is rejected' workflow_dispatch '5.0.0$(echo-owned)' false
expect_failure 'invalid boolean is rejected' workflow_dispatch 5.0.0 yes
expect_failure 'unsupported event is rejected' schedule 5.0.0 false

echo '[test-resolve-release-metadata] All scenarios passed'
