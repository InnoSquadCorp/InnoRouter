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

swift build \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SCRATCH_DIR/conditional-case-positive" \
  --jobs "$JOBS" \
  -Xswiftc -DINNOROUTER_CUSTOM_CONDITIONAL \
  --target InnoRouterMacroFirstExternalConsumer

swift test \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SCRATCH_DIR/swiftpm" \
  --jobs "$JOBS" \
  --filter InnoRouterDeveloperToolsExternalConsumerTests

if [[ "$VERSION" == "local" ]]; then
  AVAILABILITY_LOG="$SCRATCH_DIR/availability-negative.log"
  if swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_DIR/availability-negative" \
    --jobs "$JOBS" \
    -Xswiftc -DINNOROUTER_AVAILABILITY_NEGATIVE \
    --target AvailabilityNegativeConsumer >"$AVAILABILITY_LOG" 2>&1; then
    echo "[external-consumer-smoke] Failed: unguarded availability probe unexpectedly compiled" >&2
    exit 1
  fi
  if ! grep -q "futureConfirmation.*only available in macOS 26" "$AVAILABILITY_LOG"; then
    echo "[external-consumer-smoke] Failed: availability probe did not reach the expected compiler diagnostic" >&2
    cat "$AVAILABILITY_LOG" >&2
    exit 1
  fi
  if ! grep -q "conditionalFutureConfirmation.*only available in macOS 26" "$AVAILABILITY_LOG"; then
    echo "[external-consumer-smoke] Failed: conditional availability was not propagated to the generated presentation factory" >&2
    cat "$AVAILABILITY_LOG" >&2
    exit 1
  fi

  CONDITIONAL_FEATURE_LOG="$SCRATCH_DIR/conditional-feature-negative.log"
  if swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_DIR/conditional-feature-negative" \
    --jobs "$JOBS" \
    -Xswiftc -DINNOROUTER_CONDITIONAL_FEATURE_NEGATIVE \
    --target ConditionalFeatureNegativeConsumer >"$CONDITIONAL_FEATURE_LOG" 2>&1; then
    echo "[external-consumer-smoke] Failed: conditional FeatureRoute probe unexpectedly compiled" >&2
    exit 1
  fi
  if ! grep -q "InnoRouterMacro.E065" "$CONDITIONAL_FEATURE_LOG"; then
    echo "[external-consumer-smoke] Failed: conditional FeatureRoute probe missed E065" >&2
    cat "$CONDITIONAL_FEATURE_LOG" >&2
    exit 1
  fi
fi

echo "[external-consumer-smoke] 6.0 runtime, developer-product, and presentation availability contracts passed ($VERSION)"
