#!/usr/bin/env bash
# shellcheck disable=SC2076 # Quoted =~ operands intentionally perform literal membership checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
SWIFTPM_JOBS="${SWIFTPM_JOBS:-2}"
XCODEBUILD_JOBS="${XCODEBUILD_JOBS:-2}"

if ! command -v rg >/dev/null 2>&1; then
  echo "[principle-gates] Failed: ripgrep (rg) is required but was not found in PATH"
  exit 1
fi

# --platforms=all runs a per-platform build probe after the core checks.
# macOS-only CI runners can pass it to gate the Apple platform matrix
# locally without spinning up the full GitHub Actions workflow.
# Individual platforms are space- or comma-separated and must be one of:
# ios, ipados, macos, tvos, watchos, visionos.
PLATFORMS_ARG=""
for arg in "$@"; do
  case "$arg" in
    --platforms=*)
      PLATFORMS_ARG="${arg#--platforms=}"
      ;;
  esac
done

NORMALIZED_PLATFORMS_ARG=""
if [[ -n "$PLATFORMS_ARG" ]]; then
  NORMALIZED_PLATFORMS_ARG="$(echo "$PLATFORMS_ARG" | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs)"
  if [[ -z "$NORMALIZED_PLATFORMS_ARG" ]]; then
    echo "[principle-gates] Failed: --platforms= must not be empty"
    exit 1
  fi

  VALID_PLATFORM_TOKENS="all ios ipados macos tvos watchos visionos"
  for token in $NORMALIZED_PLATFORMS_ARG; do
    if [[ ! " $VALID_PLATFORM_TOKENS " =~ " $token " ]]; then
      echo "[principle-gates] Failed: unsupported platform token '$token'"
      exit 1
    fi
  done

  # Rejecting `all` combined with individual names keeps the flag
  # unambiguous. Before this guard, `--platforms=all,ios` silently
  # behaved the same as `--platforms=all`, which would have hidden
  # a typo or a confused expectation about what the probe actually
  # ran.
  TOKEN_COUNT="$(echo "$NORMALIZED_PLATFORMS_ARG" | wc -w | tr -d ' ')"
  if [[ " $NORMALIZED_PLATFORMS_ARG " == *" all "* && "$TOKEN_COUNT" != "1" ]]; then
    echo "[principle-gates] Failed: --platforms=all cannot be combined with specific platforms"
    echo "[principle-gates]         Use --platforms=all on its own, or drop 'all' and list platforms explicitly"
    exit 1
  fi
fi

# Gate 1 — runtime behavior. The full Swift Testing suite must pass.
# Failure signal: any @Test failure or build error in Tests/.
# Local repro: swift test
echo "[principle-gates] Running swift test"
swift test --jobs "$SWIFTPM_JOBS"

# Gate 2 — DocC catalogs build cleanly. Catches symbol drift,
# broken cross-references, and malformed articles before publishing.
# Failure signal: build-docc-site.sh non-zero (typically missing symbol
# or broken doc link).
# Local repro: ./scripts/build-docc-site.sh --version preview --skip-latest
echo "[principle-gates] Building DocC preview site"
./scripts/build-docc-site.sh --version preview --skip-latest

# Gate 3 — public API baseline diffs. Surfaces accidental public
# symbol additions/removals/signature changes against the recorded
# baseline so deliberate release-line changes remain reviewable.
# Failure signal: removed/renamed symbol or non-additive signature change.
# Local repro: ./scripts/check-public-api.sh
echo "[principle-gates] Checking public API baselines"
./scripts/check-public-api.sh

# Gate 4 — maintainer docs (README, CLAUDE.md, AGENTS.md, RELEASING.md,
# CHANGELOG.md) stay internally consistent (cross-references, version
# strings, headings).
# Failure signal: drift between the documents.
# Local repro: ./scripts/check-docs-consistency.sh
echo "[principle-gates] Checking maintainer docs consistency"
./scripts/check-docs-consistency.sh

# Gate 5 — Swift code blocks inside DocC and Markdown actually
# typecheck against the published API. Stops doc snippets from
# rotting after a rename.
# Failure signal: snippet fails to compile.
# Local repro: ./scripts/check-docs-code-blocks.sh
echo "[principle-gates] Checking documentation Swift code blocks"
./scripts/check-docs-code-blocks.sh

# Gate 6 — Examples/ ↔ ExamplesSmoke/ 1:1 alignment. See
# Examples/README.md for the contributor rules on which side to edit.
# Failure signal: a file present on one side missing on the other.
# Local repro: ./scripts/check-examples-parity.sh
echo "[principle-gates] Checking Examples↔ExamplesSmoke parity"
./scripts/check-examples-parity.sh

# Gate 7 — compiler-stable smoke fixtures. The dedicated macro-first target
# contains a downstream `import InnoRouter` + `@Router` fixture, so the default
# umbrella must expose both the macro declaration and generated runtime surface.
# Failure signal: smoke build error.
# Local repro: swift build --target <name>
echo "[principle-gates] Building example smoke targets"
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterExamplesSmoke
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterStandaloneExampleSmoke
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterCoordinatorExampleSmoke
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterMacroFirstSmoke
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterEffects

# Gate 8 — human-facing examples must build. These exercise the
# macro-driven, idiomatic surface that Examples/ documents.
# Failure signal: example build error.
echo "[principle-gates] Building human-facing example targets"
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterStandaloneExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterCoordinatorExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterDeepLinkExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterSplitCoordinatorExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterAppShellExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterMultiPlatformExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterVisionOSImmersiveExample
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterSampleAppExample

# Gate 9 — performance smoke. Catches gross regressions in command
# execution / engine dispatch.
# Failure signal: timing budget exceeded.
# Local repro: ./scripts/performance-smoke.sh
echo "[principle-gates] Running performance smoke"
./scripts/performance-smoke.sh

# Gate 10 — source-level lint gates (e.g. forbidden patterns,
# nonisolated(unsafe), @unchecked Sendable, debug-only fences).
# Failure signal: forbidden pattern detected.
# Local repro: ./scripts/lint-source-gates.sh
echo "[principle-gates] Running source-level lint gates"
./scripts/lint-source-gates.sh

# Gate 11 — fail-fast probe verifies that missing NavigationEnvironment
# wiring crashes deterministically with an explanatory message instead
# of producing silent fallback behavior.
# Failure signal: probe succeeded (regression — fallback re-introduced)
#                 or message missing the expected substring.
echo "[principle-gates] Checking fail-fast probe (missing NavigationEnvironmentStorage)"
PROBE_OUTPUT_FILE="$(mktemp)"
set +e
swift run --jobs "$SWIFTPM_JOBS" NavigationEnvironmentFailFastProbe >"$PROBE_OUTPUT_FILE" 2>&1
PROBE_EXIT_CODE=$?
set -e

if [[ "$PROBE_EXIT_CODE" -eq 0 ]]; then
  echo "[principle-gates] Failed: fail-fast probe unexpectedly succeeded"
  cat "$PROBE_OUTPUT_FILE"
  rm -f "$PROBE_OUTPUT_FILE"
  exit 1
fi

if ! rg -q "NavigationEnvironmentStorage is missing" "$PROBE_OUTPUT_FILE"; then
  echo "[principle-gates] Failed: fail-fast probe did not report expected message"
  cat "$PROBE_OUTPUT_FILE"
  rm -f "$PROBE_OUTPUT_FILE"
  exit 1
fi

rm -f "$PROBE_OUTPUT_FILE"

# Gate 12 — public Bool naming. Public properties of type Bool must
# start with is/has/can/should so that boolean call sites read as
# predicates. Catches accidental drift on additive minor releases.
# Failure signal: a public Bool name violating the prefix rule.
echo "[principle-gates] Checking public Bool naming"
PUBLIC_BOOL_NAMES="$(rg -n --no-heading "public (var|let) [A-Za-z_][A-Za-z0-9_]*: Bool" Sources \
  | sed -E 's/.*public (var|let) ([A-Za-z_][A-Za-z0-9_]*) *: Bool.*/\2/' || true)"

if [[ -n "$PUBLIC_BOOL_NAMES" ]]; then
  INVALID_BOOL_NAMES="$(printf '%s\n' "$PUBLIC_BOOL_NAMES" | rg -v '^(is|has|can|should)[A-Z].*' || true)"
  if [[ -n "$INVALID_BOOL_NAMES" ]]; then
    echo "[principle-gates] Failed: public Bool names must start with is/has/can/should"
    echo "$INVALID_BOOL_NAMES"
    exit 1
  fi
fi

# Gate 13 (optional) — per-platform build probe. Only runs when the
# caller passes --platforms=…; macOS-only CI runners use this to gate
# the Apple platform matrix locally without spinning up the full
# GitHub Actions workflow. Compile-only via xcodebuild against
# generic simulator destinations.
# Local repro: ./scripts/principle-gates.sh --platforms=all
if [[ -n "$PLATFORMS_ARG" ]]; then
  echo "[principle-gates] Running per-platform build probe ($PLATFORMS_ARG)"
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "[principle-gates] Failed: xcodebuild is required for per-platform probe"
    exit 1
  fi

  # Map shorthand platform names to compile-only xcodebuild destinations.
  # Generic simulator destinations avoid local / runner drift when
  # exact device names or runtime images differ.
  declare -a PLATFORM_ENTRIES
  PLATFORM_ENTRIES=(
    "iOS|generic/platform=iOS Simulator"
    "iPadOS|generic/platform=iOS Simulator"
    "macOS|platform=macOS"
    "tvOS|generic/platform=tvOS Simulator"
    "watchOS|generic/platform=watchOS Simulator"
    "visionOS|generic/platform=visionOS Simulator"
  )

  # Normalise the user's filter list: lowercase, split on , or space.
  REQUESTED="$NORMALIZED_PLATFORMS_ARG"

  MATCHED_PLATFORM_COUNT=0
  BUILT_DESTINATIONS="|"

  for entry in "${PLATFORM_ENTRIES[@]}"; do
    name="${entry%%|*}"
    dest="${entry#*|}"
    name_lc="$(echo "$name" | tr '[:upper:]' '[:lower:]')"

    if [[ "$REQUESTED" != "all" && ! " $REQUESTED " =~ " $name_lc " ]]; then
      continue
    fi

    destination_key="|$dest|"
    if [[ "$BUILT_DESTINATIONS" == *"$destination_key"* ]]; then
      echo "[principle-gates] Skipping duplicate destination for $name ($dest)"
      continue
    fi
    BUILT_DESTINATIONS+="$dest|"

    MATCHED_PLATFORM_COUNT=$((MATCHED_PLATFORM_COUNT + 1))
    echo "[principle-gates] xcodebuild build -scheme InnoRouter ($name)"
    xcodebuild build \
      -scheme InnoRouter \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterCore ($name)"
    xcodebuild build \
      -scheme InnoRouterCore \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterSwiftUI ($name)"
    xcodebuild build \
      -scheme InnoRouterSwiftUI \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterSpatial ($name)"
    xcodebuild build \
      -scheme InnoRouterSpatial \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterDeepLink ($name)"
    xcodebuild build \
      -scheme InnoRouterDeepLink \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterEffects ($name)"
    xcodebuild build \
      -scheme InnoRouterEffects \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterMacros ($name)"
    xcodebuild build \
      -scheme InnoRouterMacros \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterTesting ($name)"
    xcodebuild build \
      -scheme InnoRouterTesting \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterMacroFirstSmoke ($name)"
    xcodebuild build \
      -workspace .github/platform-tests.xcworkspace \
      -scheme InnoRouterMacroFirstSmoke \
      -destination "$dest" \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    if [[ "$name_lc" == "visionos" ]]; then
      echo "[principle-gates] xcodebuild build -scheme InnoRouterSpatialConsumerSmoke ($name)"
      xcodebuild build \
        -workspace .github/platform-tests.xcworkspace \
        -scheme InnoRouterSpatialConsumerSmoke \
        -destination "$dest" \
        -jobs "$XCODEBUILD_JOBS" \
        -quiet
    fi
  done

  if [[ "$MATCHED_PLATFORM_COUNT" -eq 0 ]]; then
    echo "[principle-gates] Failed: --platforms= matched no supported platforms"
    exit 1
  fi
fi

echo "[principle-gates] All checks passed"
