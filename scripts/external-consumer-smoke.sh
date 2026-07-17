#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/ConsumerSmoke"
VERSION="${1:-local}"
JOBS="${SWIFTPM_JOBS:-2}"

if [[ "$VERSION" != "local" ]]; then
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[external-consumer-smoke] Failed: expected a bare GA semantic version, got '$VERSION'" >&2
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

(
  cd "$PACKAGE_DIR"
  # This non-interactive smoke resolves either the current checkout or the
  # exact GA tag validated above. Avoid a local Xcode trust prompt masking the
  # actual downstream build result in a fresh DerivedData directory.
  xcodebuild build \
    -scheme InnoRouterConsumerSmoke-Package \
    -destination 'generic/platform=visionOS Simulator' \
    -derivedDataPath "$SCRATCH_DIR/xcode" \
    -jobs "${XCODEBUILD_JOBS:-2}" \
    -skipMacroValidation \
    -quiet
)

echo "[external-consumer-smoke] Macro-first and Spatial consumer contracts passed ($VERSION)"
