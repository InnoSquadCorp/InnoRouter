#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/resolve-release-metadata.sh <event> <tag> <prerelease>

Validates a release trigger and prints GitHub Actions-compatible key=value
metadata. <event> must be push or workflow_dispatch. <prerelease> must be
true or false.
EOF
}

EVENT_NAME="${1:-}"
TAG="${2:-}"
REQUESTED_PRERELEASE="${3:-}"

if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[resolve-release-metadata] python3 is required." >&2
  exit 1
fi

case "$EVENT_NAME" in
  push|workflow_dispatch) ;;
  *)
    echo "[resolve-release-metadata] Unsupported event: $EVENT_NAME" >&2
    exit 1
    ;;
esac

case "$REQUESTED_PRERELEASE" in
  true|false) ;;
  *)
    echo "[resolve-release-metadata] prerelease must be true or false." >&2
    exit 1
    ;;
esac

if ! version_kind="$(
  python3 "$ROOT_DIR/scripts/release-version-policy.py" classify "$TAG" 2>/dev/null
)"; then
  echo "[resolve-release-metadata] Unsupported release version: $TAG" >&2
  exit 1
fi

publish="true"
prerelease="false"

if [[ "$EVENT_NAME" == "push" ]]; then
  if [[ "$REQUESTED_PRERELEASE" != "false" ]]; then
    echo "[resolve-release-metadata] Tag pushes cannot set the prerelease input." >&2
    exit 1
  fi

  if [[ "$version_kind" == "ga" ]]; then
    :
  elif [[ "$version_kind" == "prerelease" ]]; then
    # The broad GitHub tag glob also sees rc/beta pushes. Treat those runs as
    # successful no-ops; the documented manual dispatch performs publication.
    publish="false"
    prerelease="true"
  else
    echo "[resolve-release-metadata] Tag pushes must use a bare GA version or supported rc/beta version." >&2
    exit 1
  fi
elif [[ "$REQUESTED_PRERELEASE" == "true" ]]; then
  if [[ "$version_kind" != "prerelease" ]]; then
    echo "[resolve-release-metadata] Pre-release tags must use <major>.<minor>.<patch>-(rc|beta).<n>." >&2
    exit 1
  fi
  prerelease="true"
else
  if [[ "$version_kind" != "ga" ]]; then
    echo "[resolve-release-metadata] GA release tags must use bare semantic versioning." >&2
    exit 1
  fi
fi

printf 'version=%s\n' "$TAG"
printf 'release_ref=refs/tags/%s\n' "$TAG"
printf 'publish=%s\n' "$publish"
printf 'prerelease=%s\n' "$prerelease"
