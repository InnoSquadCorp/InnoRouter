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
# ios, ipados, maccatalyst, macos, tvos, watchos, visionos.
PLATFORMS_ARG=""
SKIP_DOCC_SITE=0
SKIP_SOURCE_LINT=0
for arg in "$@"; do
  case "$arg" in
    --platforms=*)
      PLATFORMS_ARG="${arg#--platforms=}"
      ;;
    --skip-docc-site)
      SKIP_DOCC_SITE=1
      ;;
    --skip-source-lint)
      SKIP_SOURCE_LINT=1
      ;;
  esac
done

if [[ "$SKIP_DOCC_SITE" -ne 0 || "$SKIP_SOURCE_LINT" -ne 0 ]]; then
  if [[ "${INNOROUTER_DELEGATED_GATES:-false}" != "true" ]]; then
    echo "[principle-gates] Failed: delegated gate flags require INNOROUTER_DELEGATED_GATES=true"
    exit 1
  fi
fi

NORMALIZED_PLATFORMS_ARG=""
if [[ -n "$PLATFORMS_ARG" ]]; then
  NORMALIZED_PLATFORMS_ARG="$(echo "$PLATFORMS_ARG" | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs)"
  if [[ -z "$NORMALIZED_PLATFORMS_ARG" ]]; then
    echo "[principle-gates] Failed: --platforms= must not be empty"
    exit 1
  fi

  VALID_PLATFORM_TOKENS="all ios ipados maccatalyst macos tvos watchos visionos"
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
# Swift Testing runs tests concurrently in-process unless `--no-parallel` is
# explicit. Keep this gate deterministic on the pinned Swift 6.3.3 toolchain,
# where the full actor-heavy suite can otherwise stop making progress.
# Local repro: swift test --no-parallel
echo "[principle-gates] Running swift test"
swift test --jobs "$SWIFTPM_JOBS" --no-parallel

echo "[principle-gates] Testing platform interface flag compatibility"
./scripts/test-check-platform-interface.sh

# Gate 2 — DocC catalogs build cleanly. Catches symbol drift,
# broken cross-references, and malformed articles before publishing.
# Failure signal: build-docc-site.sh non-zero (typically missing symbol
# or broken doc link).
# Local repro: ./scripts/build-docc-site.sh --version preview --skip-latest
if [[ "$SKIP_DOCC_SITE" -eq 0 ]]; then
  echo "[principle-gates] Building DocC preview site"
  ./scripts/build-docc-site.sh --version preview --skip-latest
else
  echo "[principle-gates] DocC preview site delegated to the docs-ci job"
fi

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
python3 ./scripts/test-release-identity.py
./scripts/check-docs-consistency.sh

# Gate 5 — Swift code blocks inside DocC and Markdown actually
# typecheck against the published API. Stops doc snippets from
# rotting after a rename.
# Failure signal: snippet fails to compile.
# Local repro: ./scripts/check-docs-code-blocks.sh
echo "[principle-gates] Checking documentation Swift code blocks"
./scripts/check-docs-code-blocks.sh

# Gate 6 — compiler-stable macro fixture. The dedicated macro-first target
# contains a downstream `import InnoRouter` + `@Router` fixture, so the default
# umbrella must expose both the macro declaration and generated runtime surface.
# Failure signal: smoke build error.
# Local repro: swift build --target <name>
echo "[principle-gates] Building example smoke targets"
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterMacroFirstSmoke
swift build --jobs "$SWIFTPM_JOBS" --target InnoRouterTabRestorationExample

# Gate 7 — independent SwiftPM consumer boundary. Unlike the root smoke
# targets, this nested package resolves InnoRouter as a package dependency and
# therefore catches product discovery, umbrella re-export, and plugin wiring
# regressions. The same fixture accepts an exact remote version after release.
echo "[principle-gates] Building independent package consumer smoke"
./scripts/external-consumer-smoke.sh
./scripts/generated-scenario-smoke.sh

# Gate 8 — source-level lint gates (e.g. forbidden patterns,
# nonisolated(unsafe), @unchecked Sendable, debug-only fences).
# Failure signal: forbidden pattern detected.
# Local repro: ./scripts/lint-source-gates.sh
if [[ "$SKIP_SOURCE_LINT" -eq 0 ]]; then
  echo "[principle-gates] Running source-level lint gates"
  ./scripts/lint-source-gates.sh
else
  echo "[principle-gates] Source-level lint delegated to the principle-gates lint job"
fi

# Gate 9 — fail-fast probe verifies that a missing router authority
# wiring crashes deterministically with an explanatory message instead
# of producing silent fallback behavior.
# Failure signal: probe succeeded (regression — fallback re-introduced)
#                 or message missing the expected substring.
# A recursive `@FeatureRoute` graph must terminate in every generated
# deep-link entry point instead of recursing until the stack overflows.
# Failure signal: non-zero exit (a crash reports 139) or a semantic result
#                 envelope that does not exactly match the expected contract.
echo "[principle-gates] Checking recursive deep-link traversal probe"
./scripts/test-recursive-deep-link-probe-gate.sh
RECURSIVE_PROBE_OUTPUT_FILE="$(mktemp)"
set +e
swift run --jobs "$SWIFTPM_JOBS" RouterRecursiveDeepLinkProbe >"$RECURSIVE_PROBE_OUTPUT_FILE" 2>&1
RECURSIVE_PROBE_EXIT_CODE=$?
set -e

if [[ "$RECURSIVE_PROBE_EXIT_CODE" -ne 0 ]]; then
  echo "[principle-gates] Failed: recursive deep-link probe exited $RECURSIVE_PROBE_EXIT_CODE"
  cat "$RECURSIVE_PROBE_OUTPUT_FILE"
  rm -f "$RECURSIVE_PROBE_OUTPUT_FILE"
  exit 1
fi

if ! python3 ./scripts/validate-recursive-deep-link-probe.py "$RECURSIVE_PROBE_OUTPUT_FILE"; then
  echo "[principle-gates] Failed: recursive deep-link probe reported invalid semantics"
  cat "$RECURSIVE_PROBE_OUTPUT_FILE"
  rm -f "$RECURSIVE_PROBE_OUTPUT_FILE"
  exit 1
fi
rm -f "$RECURSIVE_PROBE_OUTPUT_FILE"

echo "[principle-gates] Checking fail-fast probe (missing router authority)"
PROBE_OUTPUT_FILE="$(mktemp)"
set +e
swift run --jobs "$SWIFTPM_JOBS" RouterEnvironmentFailFastProbe >"$PROBE_OUTPUT_FILE" 2>&1
PROBE_EXIT_CODE=$?
set -e

if [[ "$PROBE_EXIT_CODE" -eq 0 ]]; then
  echo "[principle-gates] Failed: fail-fast probe unexpectedly succeeded"
  cat "$PROBE_OUTPUT_FILE"
  rm -f "$PROBE_OUTPUT_FILE"
  exit 1
fi

if ! rg -q "Router authority is missing" "$PROBE_OUTPUT_FILE"; then
  echo "[principle-gates] Failed: fail-fast probe did not report expected message"
  cat "$PROBE_OUTPUT_FILE"
  rm -f "$PROBE_OUTPUT_FILE"
  exit 1
fi

rm -f "$PROBE_OUTPUT_FILE"

# Gate 10 — public Bool naming. Public properties of type Bool must
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

# Gate 11 (optional) — per-platform build probe. Only runs when the
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
  PLATFORM_DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-platforms.XXXXXX")"
  trap 'rm -rf "$PLATFORM_DERIVED_DATA"' EXIT

  # Map shorthand platform names to compile-only xcodebuild destinations.
  # Generic simulator destinations avoid local / runner drift when
  # exact device names or runtime images differ.
  declare -a PLATFORM_ENTRIES
  PLATFORM_ENTRIES=(
    "iOS|generic/platform=iOS Simulator"
    "iPadOS|generic/platform=iOS Simulator"
    "Mac-Catalyst|generic/platform=macOS,variant=Mac Catalyst"
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
    name_token="${name_lc//-/}"

    if [[ "$REQUESTED" != "all" && ! " $REQUESTED " =~ " $name_token " ]]; then
      continue
    fi

    destination_key="|$dest|"
    if [[ "$BUILT_DESTINATIONS" == *"$destination_key"* ]]; then
      echo "[principle-gates] Skipping duplicate destination for $name ($dest)"
      continue
    fi
    BUILT_DESTINATIONS+="$dest|"

    MATCHED_PLATFORM_COUNT=$((MATCHED_PLATFORM_COUNT + 1))
    echo "[principle-gates] xcodebuild build -scheme InnoRouterMacroFirstSmoke ($name)"
    xcodebuild build \
      -workspace .github/platform-tests.xcworkspace \
      -scheme InnoRouterMacroFirstSmoke \
      -destination "$dest" \
      -derivedDataPath "$PLATFORM_DERIVED_DATA/$name_token" \
      -configuration Release \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] xcodebuild build -scheme InnoRouterDeveloperToolsSmoke ($name)"
    xcodebuild build \
      -workspace .github/platform-tests.xcworkspace \
      -scheme InnoRouterDeveloperToolsSmoke \
      -destination "$dest" \
      -derivedDataPath "$PLATFORM_DERIVED_DATA/$name_token" \
      -configuration Release \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
      -jobs "$XCODEBUILD_JOBS" \
      -quiet

    echo "[principle-gates] Validating public interfaces ($name)"
    ./scripts/check-platform-interface.sh "$PLATFORM_DERIVED_DATA/$name_token" "$name"

  done

  if [[ "$MATCHED_PLATFORM_COUNT" -eq 0 ]]; then
    echo "[principle-gates] Failed: --platforms= matched no supported platforms"
    exit 1
  fi
fi

echo "[principle-gates] All checks passed"
