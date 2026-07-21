#!/usr/bin/env bash
set -euo pipefail

# Source-level lint gates extracted from `principle-gates.sh` so they
# can run independently — locally during edit/refactor work, and on
# CI in parallel with the heavier `swift test` and DocC build steps.
#
# The full set of gates remains driven by `principle-gates.sh`; this
# script is the authoritative implementation, and the parent gate
# script delegates to it. A future SwiftSyntax-based linter can
# replace these grep checks one rule at a time without touching the
# parent script's call signature.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "[lint-source-gates] Failed: ripgrep (rg) is required but was not found in PATH"
  exit 1
fi

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[lint-source-gates] Failed: $tool is required but was not found in PATH"
    exit 1
  fi
}

require_file() {
  local path="$1"
  local description="$2"
  if [[ ! -f "$path" ]]; then
    echo "[lint-source-gates] Failed: $description is required at $path"
    exit 1
  fi
}

echo "[lint-source-gates] Checking swiftformat in lint mode"
require_tool swiftformat
require_file .swiftformat "swiftformat configuration"
swiftformat Sources Tests Examples ExamplesSmoke ConsumerSmoke/Sources Package.swift ConsumerSmoke/Package.swift --lint

MACRO_PATTERN_SOURCE="Sources/InnoRouterPatternSupport/RoutePattern.swift"
RUNTIME_PATTERN_SOURCE="Sources/InnoRouterDeepLink/RoutePattern.swift"
if ! cmp -s "$MACRO_PATTERN_SOURCE" "$RUNTIME_PATTERN_SOURCE"; then
  echo "[lint-source-gates] Failed: macro-host and runtime route-pattern grammar sources differ" >&2
  echo "[lint-source-gates]         Keep $MACRO_PATTERN_SOURCE and $RUNTIME_PATTERN_SOURCE identical" >&2
  exit 1
fi

echo "[lint-source-gates] Checking immutable GitHub Action references"
MUTABLE_ACTION_REFS="$(
  rg -n --no-heading '^\s*uses:\s+[^./][^@]*@' .github/workflows \
    | rg -v '@[0-9a-f]{40}([[:space:]]+#.*)?$' || true
)"
if [[ -n "$MUTABLE_ACTION_REFS" ]]; then
  echo "[lint-source-gates] Failed: external GitHub Actions must use full commit SHAs" >&2
  echo "$MUTABLE_ACTION_REFS" >&2
  exit 1
fi

echo "[lint-source-gates] Checking swiftlint in strict mode"
require_tool swiftlint
require_file .swiftlint.yml "swiftlint configuration"
swiftlint lint --strict --config .swiftlint.yml

echo "[lint-source-gates] Checking production responsibility budgets"
require_file .swiftlint.sources.yml "production swiftlint configuration"
swiftlint lint --strict --config .swiftlint.sources.yml

echo "[lint-source-gates] Checking non-ASCII letters in source comments (Hangul, etc.)"
# Public-facing comments and docstrings must be English so the
# library is usable outside the original team's locale. Test
# fixtures still legitimately exercise non-ASCII payloads (see
# `DeepLinkPercentEncodingTests`); restrict the check to Sources/
# and the user-facing example trees.
if rg -nP '[\p{Hangul}]' Sources Examples ExamplesSmoke; then
  echo "[lint-source-gates] Failed: non-ASCII (Hangul) characters found in source comments"
  exit 1
fi

echo "[lint-source-gates] Checking Nav* public symbols"
if rg -n "public .*\\bNav[A-Z]" Sources; then
  echo "[lint-source-gates] Failed: legacy Nav* public symbols found"
  exit 1
fi

echo "[lint-source-gates] Checking active repository guidance for legacy APIs"
if rg -n '\bNav[A-Z][[:alnum:]_]*\b|@UseNavigator\b|@EnvironmentNavigator\b|\bPendingNav\b|\.conditional[[:space:]]*\(|@unchecked[[:space:]]+Sendable|\b(onChange|onBatchExecuted|onTransactionExecuted|onMiddlewareMutation|onPathMismatch|onPresented|onDismissed|onReplaced|onQueueChanged|onCommandIntercepted|onPathChanged|onIntentRejected)[[:space:]]*:' \
  .cursor/rules --glob '*.mdc'; then
  echo "[lint-source-gates] Failed: active .cursor guidance references removed or unsafe APIs"
  exit 1
fi

echo "[lint-source-gates] Checking deprecated/availability shims"
# `RouterSplitHost` intentionally keeps an unavailable watchOS declaration so
# the compiler can direct macro-first callers to `RouterHost`. That is a
# platform diagnostic, not a compatibility shim. Keep the exception scoped to
# this one source file; every other availability declaration still fails.
if rg -n "deprecated|@available\\(" Sources \
  --glob '*.swift' \
  --glob '!**/NavigationStore.swift' \
  --glob '!**/RouterSplitHost.swift'; then
  echo "[lint-source-gates] Failed: deprecated or availability shim found"
  exit 1
fi

echo "[lint-source-gates] Checking watchOS split-host unavailability contract"
require_tool python3
require_file Sources/InnoRouterSwiftUI/RouterSplitHost.swift "RouterSplitHost source"
if ! python3 - <<'PY'
import re
from pathlib import Path

source = Path("Sources/InnoRouterSwiftUI/RouterSplitHost.swift").read_text(
    encoding="utf-8"
)
parts = source.split("\n#else\n")
if len(parts) != 2 or "\n#if !os(watchOS)\n" not in parts[0]:
    raise SystemExit("RouterSplitHost must keep one explicit watchOS fallback branch")

watch_branch = parts[1].rsplit("\n#endif", maxsplit=1)[0]
contract = re.compile(
    r"""
    @available\(
        \s*watchOS,\s*
        unavailable,\s*
        message:\s*"RouterSplitHost\ requires\ NavigationSplitView;\ use\ RouterHost\ on\ watchOS\."\s*
    \)
    \s*@MainActor
    \s*public\ struct\ RouterSplitHost
    """,
    flags=re.VERBOSE,
)
if contract.search(watch_branch) is None:
    raise SystemExit(
        "watchOS RouterSplitHost must remain explicitly unavailable with recovery guidance"
    )
PY
then
  echo "[lint-source-gates] Failed: RouterSplitHost watchOS unavailable contract drifted"
  exit 1
fi

echo "[lint-source-gates] Checking single Effects product boundary"
for legacy_effects_module in InnoRouterNavigationEffects InnoRouterDeepLinkEffects; do
  if [[ -e "Sources/$legacy_effects_module" ]] \
    || rg -q "name: \"$legacy_effects_module\"" Package.swift; then
    echo "[lint-source-gates] Failed: $legacy_effects_module must be folded into InnoRouterEffects for 5.0"
    exit 1
  fi
done

echo "[lint-source-gates] Checking legacy SwiftUI navigator surface"
if rg -n "@EnvironmentNavigator|public func navigator\\(" Sources Examples ExamplesSmoke README.md; then
  echo "[lint-source-gates] Failed: legacy navigator API found"
  exit 1
fi

echo "[lint-source-gates] Checking removed navigator type erasers"
if rg -n '\b(AnyNavigator|AnyBatchNavigator)\b' \
  Sources Tests Examples ExamplesSmoke README*.md Docs AGENTS.md CLAUDE.md .cursor \
  --glob '*.swift' --glob '*.md' --glob '*.mdc' \
  --glob '!**/Migrating-To-InnoRouter-*.md'; then
  echo "[lint-source-gates] Failed: removed navigator type eraser found"
  exit 1
fi

echo "[lint-source-gates] Checking legacy type-specific environment wrappers"
if rg -n '\b(EnvironmentNavigationIntent|EnvironmentModalIntent|EnvironmentFlowIntent|NavigationEnvironmentStorage|ModalEnvironmentStorage|FlowEnvironmentStorage)\b' \
  Sources Examples ExamplesSmoke --glob '*.swift'; then
  echo "[lint-source-gates] Failed: legacy type-specific environment wrapper found"
  exit 1
fi

echo "[lint-source-gates] Checking race-safe event stream examples"
if rg -n 'for await[[:space:]].*[[:space:]]in[[:space:]].*\.events' \
  Sources Docs README*.md AGENTS.md CLAUDE.md --glob '*.md'; then
  echo "[lint-source-gates] Failed: capture store.events before starting its consumer Task so immediate events cannot race subscription registration" >&2
  exit 1
fi

echo "[lint-source-gates] Checking AnyCoordinator removal"
if rg -n "AnyCoordinator" Sources Examples ExamplesSmoke README.md; then
  echo "[lint-source-gates] Failed: AnyCoordinator symbol found"
  exit 1
fi

echo "[lint-source-gates] Checking removed coordinator lifecycle capability"
if rg -n '\b(LifecycleAware|LifecycleSignals|lifecycleSignals)\b' \
  Sources Examples ExamplesSmoke --glob '*.swift'; then
  echo "[lint-source-gates] Failed: removed coordinator lifecycle capability found"
  exit 1
fi

echo "[lint-source-gates] Checking optional intent dispatch usage"
if rg -n "navigationIntent\\?\\.send" Sources Examples ExamplesSmoke README.md RELEASING.md CLAUDE.md Docs --glob '*.swift' --glob '*.md'; then
  echo "[lint-source-gates] Failed: optional intent dispatch usage found"
  exit 1
fi

echo "[lint-source-gates] Checking deep-link intent removal from SwiftUI surface"
if rg -n "\\.deepLink\\(|case \\.deepLink" Sources/InnoRouterSwiftUI Sources/InnoRouterUmbrella Examples ExamplesSmoke README.md Tests/InnoRouterTests; then
  echo "[lint-source-gates] Failed: deep-link intent surface found"
  exit 1
fi

echo "[lint-source-gates] Checking deep-link fallback removal"
if rg -n "about:blank|schemeNotAllowed\\(actualScheme: nil\\)" Sources/InnoRouterEffects; then
  echo "[lint-source-gates] Failed: legacy fallback found"
  exit 1
fi

echo "[lint-source-gates] Checking duplicate coordinator deep-link removal"
if rg -n "DeepLinkCoordinating|DeepLinkCoordinationOutcome|resumePendingDeepLinkIfPossible" \
  Sources Tests Examples ExamplesSmoke README*.md Docs .cursor \
  --glob '*.swift' --glob '*.md' --glob '*.mdc' \
  --glob '!**/Migrating-To-InnoRouter-*.md'; then
  echo "[lint-source-gates] Failed: removed coordinator deep-link surface found"
  exit 1
fi

echo "[lint-source-gates] Checking @unchecked Sendable removal"
if rg -n "@unchecked Sendable" Sources Tests; then
  echo "[lint-source-gates] Failed: @unchecked Sendable usage found"
  exit 1
fi

echo "[lint-source-gates] Checking modal trace privacy"
if rg -n -F 'metadata=\(metadataSummary, privacy: .public)' Sources/InnoRouterSwiftUI/ModalStore.swift \
  || rg -n -F 'outcome=\(outcome, privacy: .public)' Sources/InnoRouterSwiftUI/ModalStore.swift; then
  echo "[lint-source-gates] Failed: modal trace metadata/outcome must stay private"
  exit 1
fi

echo "[lint-source-gates] Checking route and command telemetry privacy"
if rg -ni '(summary|route|command|intent|path|reason|debugname|cancellation|payload|metadata)=.*privacy: \.public' \
  Sources/InnoRouterSwiftUI --glob '*.swift'; then
  echo "[lint-source-gates] Failed: route, command, reason, and event summary payloads must stay private"
  exit 1
fi

echo "[lint-source-gates] Checking arbitrary runtime error privacy"
if rg -n -F '\(description, privacy: .public)' Sources/InnoRouterSwiftUI/DebouncingNavigator.swift; then
  echo "[lint-source-gates] Failed: arbitrary runtime error descriptions must stay private"
  exit 1
fi

echo "[lint-source-gates] Checking README SwiftUI philosophy section uniqueness"
SWIFTUI_ALIGNMENT_SECTION_COUNT="$(rg -n "^### SwiftUI Philosophy Alignment$" README.md | wc -l | tr -d ' ' || true)"
if [[ "$SWIFTUI_ALIGNMENT_SECTION_COUNT" != "1" ]]; then
  echo "[lint-source-gates] Failed: expected 1 SwiftUI Philosophy Alignment section, got $SWIFTUI_ALIGNMENT_SECTION_COUNT"
  exit 1
fi

echo "[lint-source-gates] Checking documentation for semver tag formatting"
if rg -n '\bvX\.Y\.Z\b|\bv[0-9]+\.[0-9]+\.[0-9]+\b' README.md RELEASING.md CLAUDE.md Docs Sources --glob '*.md'; then
  echo "[lint-source-gates] Failed: documentation still references v-prefixed release tags"
  exit 1
fi

echo "[lint-source-gates] Checking documentation for renamed path mismatch policy symbols"
if rg -n 'NonPrefixPathRewritePolicy|NonPrefixPathRewriteResolution|nonPrefixPathRewritePolicy' README.md RELEASING.md CLAUDE.md Docs Sources --glob '*.md'; then
  echo "[lint-source-gates] Failed: documentation still references legacy path mismatch symbols"
  exit 1
fi

echo "[lint-source-gates] Checking documentation for legacy effect module names"
if rg -n 'Sources/InnoRouterEffects/NavigationEffectHandler.swift|Sources/InnoRouterEffects/DeepLinkEffectHandler.swift' README.md RELEASING.md CLAUDE.md Docs Sources --glob '*.md'; then
  echo "[lint-source-gates] Failed: documentation still references legacy effect implementation paths"
  exit 1
fi

echo "[lint-source-gates] All source-level lint gates passed"
