#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
SITE_DIR="${2:-}"

if [[ $# -ne 2 ]]; then
  echo "Usage: resolve-latest-publication.sh <version> <existing-site-dir>" >&2
  exit 2
fi

if [[ ! -d "$SITE_DIR" ]]; then
  echo "[resolve-latest-publication] Existing site directory not found: $SITE_DIR" >&2
  exit 1
fi

if ! version_kind="$(
  python3 "$ROOT_DIR/scripts/release-version-policy.py" classify "$VERSION"
)"; then
  exit 1
fi

if [[ "$version_kind" == "prerelease" ]]; then
  printf 'action=skip\n'
  printf 'latest_version=\n'
  printf 'make_latest=false\n'
  printf 'skip_latest=true\n'
  exit 0
fi

if ! decision="$(
  find "$SITE_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    ! -name latest \
    -exec basename {} \; |
    python3 "$ROOT_DIR/scripts/release-version-policy.py" latest-action "$VERSION"
)"; then
  echo "[resolve-latest-publication] Failed to compare $VERSION with the existing site." >&2
  exit 1
fi

read -r action latest_version <<< "$decision"
case "$action" in
  update)
    make_latest=true
    skip_latest=false
    ;;
  preserve)
    if [[ ! -d "$SITE_DIR/latest" ]]; then
      echo "[resolve-latest-publication] Cannot preserve /latest at $latest_version because the alias is missing." >&2
      exit 1
    fi
    make_latest=false
    skip_latest=true
    ;;
  *)
    echo "[resolve-latest-publication] Unexpected policy decision: $decision" >&2
    exit 1
    ;;
esac

printf 'action=%s\n' "$action"
printf 'latest_version=%s\n' "$latest_version"
printf 'make_latest=%s\n' "$make_latest"
printf 'skip_latest=%s\n' "$skip_latest"
