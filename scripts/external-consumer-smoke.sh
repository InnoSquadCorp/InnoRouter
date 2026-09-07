#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/ConsumerSmoke"
VERSION="${1:-local}"
JOBS="${SWIFTPM_JOBS:-2}"

if [[ "$VERSION" != "local" ]]; then
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[external-consumer-smoke] Failed: expected bare GA semver, got '$VERSION'" >&2
    exit 1
  fi
  export INNOROUTER_CONSUMER_VERSION="$VERSION"
  CACHE_KEY="$VERSION"
  echo "[external-consumer-smoke] Resolving exact remote release $VERSION"
else
  unset INNOROUTER_CONSUMER_VERSION || true
  CACHE_KEY="local"
  echo "[external-consumer-smoke] Resolving local checkout"
fi

SCRATCH_DIR="$ROOT_DIR/.build/external-consumer/$CACHE_KEY"

swift build \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SCRATCH_DIR/swiftpm" \
  --jobs "$JOBS" \
  --target InnoRouterMacroFirstExternalConsumer

swift test \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SCRATCH_DIR/swiftpm" \
  --jobs "$JOBS" \
  --filter InnoRouterDeveloperToolsExternalConsumerTests

echo "[external-consumer-smoke] 6.0 runtime and developer-product contracts passed ($VERSION)"
