#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/verify-release-ref.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-release-ref.XXXXXX")"
REPOSITORY="$TEMP_ROOT/repository"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

expect_success() {
  local name="$1"
  local expected_commit="$2"
  shift 2

  local output
  if ! output="$(cd "$REPOSITORY" && bash "$SUBJECT" "$@" 2>&1)"; then
    echo "[test-verify-release-ref] $name: expected success" >&2
    printf '%s\n' "$output" | sed 's/^/[test-verify-release-ref]   /' >&2
    exit 1
  fi

  if [[ "$output" != "commit_sha=$expected_commit" ]]; then
    echo "[test-verify-release-ref] $name: unexpected output" >&2
    printf '%s\n' "$output" | sed 's/^/[test-verify-release-ref]   /' >&2
    exit 1
  fi

  echo "[test-verify-release-ref] $name: passed"
}

expect_failure() {
  local name="$1"
  shift

  if (cd "$REPOSITORY" && bash "$SUBJECT" "$@" >/dev/null 2>&1); then
    echo "[test-verify-release-ref] $name: expected failure" >&2
    exit 1
  fi

  echo "[test-verify-release-ref] $name: failed as expected"
}

git init --quiet --initial-branch=main "$REPOSITORY"
git -C "$REPOSITORY" config user.name 'Release Ref Test'
git -C "$REPOSITORY" config user.email 'release-ref-test@example.com'

printf 'root\n' > "$REPOSITORY/fixture.txt"
git -C "$REPOSITORY" add fixture.txt
git -C "$REPOSITORY" commit --quiet -m 'root'
ROOT_COMMIT="$(git -C "$REPOSITORY" rev-parse HEAD)"

printf 'main\n' >> "$REPOSITORY/fixture.txt"
git -C "$REPOSITORY" commit --quiet -am 'main'
MAIN_COMMIT="$(git -C "$REPOSITORY" rev-parse HEAD)"

git -C "$REPOSITORY" tag 5.0.0 "$ROOT_COMMIT"
LIGHTWEIGHT_SHA="$(git -C "$REPOSITORY" rev-parse refs/tags/5.0.0)"

git -C "$REPOSITORY" tag -a 5.0.1 -m '5.0.1' "$MAIN_COMMIT"
ANNOTATED_SHA="$(git -C "$REPOSITORY" rev-parse refs/tags/5.0.1)"

expect_success \
  'lightweight tag push' \
  "$ROOT_COMMIT" \
  push refs/tags/5.0.0 "$LIGHTWEIGHT_SHA" refs/tags/5.0.0 refs/heads/main

expect_success \
  'annotated tag push peels the event object' \
  "$MAIN_COMMIT" \
  push refs/tags/5.0.1 "$ANNOTATED_SHA" refs/tags/5.0.1 refs/heads/main

expect_success \
  'manual dispatch from main' \
  "$ROOT_COMMIT" \
  workflow_dispatch refs/heads/main "$MAIN_COMMIT" refs/tags/5.0.0 refs/heads/main

git -C "$REPOSITORY" branch 5.0.2 "$MAIN_COMMIT"
expect_failure \
  'same-name branch cannot replace a missing tag' \
  workflow_dispatch refs/heads/main "$MAIN_COMMIT" refs/tags/5.0.2 refs/heads/main

git -C "$REPOSITORY" switch --quiet -c side "$ROOT_COMMIT"
printf 'side\n' > "$REPOSITORY/side.txt"
git -C "$REPOSITORY" add side.txt
git -C "$REPOSITORY" commit --quiet -m 'side'
SIDE_COMMIT="$(git -C "$REPOSITORY" rev-parse HEAD)"
git -C "$REPOSITORY" tag 5.0.3 "$SIDE_COMMIT"
git -C "$REPOSITORY" switch --quiet main

expect_failure \
  'tag outside main ancestry' \
  workflow_dispatch refs/heads/main "$MAIN_COMMIT" refs/tags/5.0.3 refs/heads/main

BLOB_SHA="$(printf 'release blob\n' | git -C "$REPOSITORY" hash-object -w --stdin)"
git -C "$REPOSITORY" update-ref refs/tags/5.0.4 "$BLOB_SHA"
expect_failure \
  'tag that does not peel to a commit' \
  workflow_dispatch refs/heads/main "$MAIN_COMMIT" refs/tags/5.0.4 refs/heads/main

expect_failure \
  'push event ref mismatch' \
  push refs/tags/5.0.1 "$LIGHTWEIGHT_SHA" refs/tags/5.0.0 refs/heads/main

git -C "$REPOSITORY" tag 5.0.5 "$ROOT_COMMIT"
MOVED_EVENT_SHA="$(git -C "$REPOSITORY" rev-parse refs/tags/5.0.5)"
git -C "$REPOSITORY" tag --force 5.0.5 "$MAIN_COMMIT" >/dev/null
expect_failure \
  'moved tag does not match the event SHA' \
  push refs/tags/5.0.5 "$MOVED_EVENT_SHA" refs/tags/5.0.5 refs/heads/main

expect_failure \
  'manual dispatch from a non-main branch' \
  workflow_dispatch refs/heads/feature "$MAIN_COMMIT" refs/tags/5.0.0 refs/heads/main

echo '[test-verify-release-ref] All scenarios passed'
