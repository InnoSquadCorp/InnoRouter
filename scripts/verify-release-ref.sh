#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-release-ref.sh <event> <event-ref> <event-sha> <release-ref> <main-ref>

Verifies that <release-ref> is an exact tag whose commit is reachable from
<main-ref>. Push events must describe that same tag and commit. Manual release
dispatches must originate from refs/heads/main.
EOF
}

fail() {
  echo "[verify-release-ref] $*" >&2
  exit 1
}

if [[ $# -ne 5 ]]; then
  usage >&2
  exit 2
fi

EVENT_NAME="$1"
EVENT_REF="$2"
EVENT_SHA="$3"
RELEASE_REF="$4"
MAIN_REF="$5"

case "$EVENT_NAME" in
  push|workflow_dispatch) ;;
  *) fail "Unsupported event: $EVENT_NAME" ;;
esac

if [[ "$RELEASE_REF" != refs/tags/* ]]; then
  fail "Release ref must be an exact tag ref: $RELEASE_REF"
fi

if ! git check-ref-format "$RELEASE_REF"; then
  fail "Release ref is not a valid Git ref: $RELEASE_REF"
fi

if ! git show-ref --verify --quiet "$RELEASE_REF"; then
  fail "Release tag does not exist exactly: $RELEASE_REF"
fi

if ! git check-ref-format "$MAIN_REF"; then
  fail "Main ref is not a valid Git ref: $MAIN_REF"
fi

if ! git show-ref --verify --quiet "$MAIN_REF"; then
  fail "Main ref does not exist exactly: $MAIN_REF"
fi

if ! tag_commit="$(git rev-parse --verify "${RELEASE_REF}^{commit}" 2>/dev/null)"; then
  fail "Release tag does not peel to a commit: $RELEASE_REF"
fi

if ! main_commit="$(git rev-parse --verify "${MAIN_REF}^{commit}" 2>/dev/null)"; then
  fail "Main ref does not peel to a commit: $MAIN_REF"
fi

case "$EVENT_NAME" in
  push)
    if [[ "$EVENT_REF" != "$RELEASE_REF" ]]; then
      fail "Push event ref does not match the release tag: $EVENT_REF"
    fi

    if [[ ! "$EVENT_SHA" =~ ^[0-9a-fA-F]{40}$ && ! "$EVENT_SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
      fail "Push event SHA is not a full object ID: $EVENT_SHA"
    fi

    if ! event_commit="$(git rev-parse --verify "${EVENT_SHA}^{commit}" 2>/dev/null)"; then
      fail "Push event SHA does not peel to a commit: $EVENT_SHA"
    fi

    if [[ "$event_commit" != "$tag_commit" ]]; then
      fail "Release tag no longer points to the pushed commit: $RELEASE_REF"
    fi
    ;;
  workflow_dispatch)
    if [[ "$EVENT_REF" != "refs/heads/main" ]]; then
      fail "Manual release dispatches must originate from refs/heads/main: $EVENT_REF"
    fi
    ;;
esac

if ! git merge-base --is-ancestor "$tag_commit" "$main_commit"; then
  fail "Release tag commit must be reachable from $MAIN_REF: $RELEASE_REF"
fi

printf 'commit_sha=%s\n' "$tag_commit"
