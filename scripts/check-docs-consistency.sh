#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

for required in rg swift python3; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "[check-docs-consistency] Failed: $required is required" >&2
    exit 1
  }
done

failures=0
CHANGELOG_PATH="${CHANGELOG_PATH:-CHANGELOG.md}"

require_file() {
  [[ -f "$1" ]] || {
    echo "[check-docs-consistency] Failed: missing $1" >&2
    failures=1
  }
}

require_literal() {
  if ! grep -F -- "$2" "$1" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $3" >&2
    failures=1
  fi
}

reject_pattern() {
  if grep -E -- "$2" "$1" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $3" >&2
    grep -En -- "$2" "$1" >&2 || true
    failures=1
  fi
}

PUBLIC_DOCS=(
  README.md
  README.ko.md
  AGENTS.md
  CLAUDE.md
  CONTRIBUTING.md
  RELEASING.md
  Examples/README.md
  ExamplesSmoke/README.md
  CHANGELOG.md
  Docs/v6-functional-strategy.md
  Docs/v6-api-convergence-spike.md
  Docs/functional-expansion-spec.md
  Docs/functional-expansion-technical-plan.md
  Docs/6.0.0-release-checklist.md
  Docs/inspector-localization.md
  Sources/InnoRouterUmbrella/InnoRouter.docc/InnoRouter.md
  Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md
  Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/InnoRouterDeepLink.md
  Sources/InnoRouterMacros/InnoRouterMacros.docc/Router-Macro-First.md
  Sources/InnoRouterTesting/InnoRouterTesting.docc/InnoRouterTesting.md
  Sources/InnoRouterInspector/InnoRouterInspector.docc/InnoRouterInspector.md
)
for path in "${PUBLIC_DOCS[@]}"; do require_file "$path"; done

require_literal Package.swift "swift-tools-version: 6.3" "Package.swift must remain on Swift 6.3"
require_literal Sources/InnoRouterCore/InnoRouterVersion.swift 'public static let current = "6.0.0"' "runtime release identity must match the 6.0 candidate"
for readme in README.md README.ko.md; do
  require_literal "$readme" "Swift 6.3+" "$readme must document Swift 6.3+"
  require_literal "$readme" 'from: "6.0.0"' "$readme must install the 6.0 line"
  require_literal "$readme" '.product(name: "InnoRouter", package: "InnoRouter")' "$readme must use the umbrella product"
  require_literal "$readme" "@Router" "$readme must lead with macro-first setup"
  require_literal "$readme" "RouterStore" "$readme must document RouterStore"
  require_literal "$readme" "RouterAction" "$readme must document RouterAction"
  require_literal "$readme" "RouterPlan" "$readme must document RouterPlan"
  require_literal "$readme" "Docs/inspector-localization.md" "$readme must link Inspector localization guidance"
done

require_literal README.md "## 30-second quick start" "README.md is missing its quick start"
require_literal README.ko.md "## 30초 Quick Start" "README.ko.md is missing its quick start"
require_file "$CHANGELOG_PATH"
bash scripts/check-changelog-phase.sh "$CHANGELOG_PATH" || failures=1
require_literal "$CHANGELOG_PATH" "### Breaking" "the 6.0 breaking section is missing"
require_literal Docs/v6-functional-strategy.md "Status: Draft" "strategy must remain Draft pending review"
require_literal Docs/functional-expansion-spec.md "FR6-012 Breaking public convergence" "spec must own the breaking API gate"
require_literal Docs/6.0.0-release-checklist.md "Xcode 26.6 / Swift 6.3" "release checklist must retain the pinned toolchain gate"
require_literal Docs/6.0.0-release-checklist.md "Not run until a 6.0.0 tag exists" "release checklist must not claim exact-tag validation early"
require_literal Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md "This is a breaking migration" "migration guide must reject alias migration"
require_file ExamplesSmoke/DeveloperToolsSmoke.swift
require_file .github/platform-tests.xcworkspace/xcshareddata/xcschemes/InnoRouterDeveloperToolsSmoke.xcscheme
require_literal Package.swift 'name: "InnoRouterDeveloperToolsSmoke"' "developer tools platform consumer target is missing"

python3 - <<'PY' || failures=1
from __future__ import annotations
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path.cwd()
fixture_source = (root / "Sources/InnoRouterTesting/RouterScenarioFixture.swift").read_text()
fixture_version = re.search(r"currentFormatVersion: Int \{ (\d+) \}", fixture_source)
if fixture_version is None:
    raise SystemExit("[check-docs-consistency] Cannot find scenario fixture format version")
for filename, prefix in (("README.md", "Fixture format v"), ("README.ko.md", "fixture v")):
    if prefix + fixture_version.group(1) not in (root / filename).read_text():
        raise SystemExit(f"[check-docs-consistency] {filename} scenario fixture version is stale")

package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True))
actual = [p["name"] for p in package["products"] if isinstance(p.get("type"), dict) and "library" in p["type"]]
expected = ["InnoRouter", "InnoRouterInspector", "InnoRouterTesting"]
if actual != expected:
    print(f"[check-docs-consistency] Failed: products are {actual}, expected {expected}", file=sys.stderr)
    raise SystemExit(1)

actual_baselines = sorted(p.name for p in (root / "Baselines/PublicAPI").glob("*.txt"))
expected_baselines = sorted(f"{name}.txt" for name in expected)
if actual_baselines != expected_baselines:
    print(f"[check-docs-consistency] Failed: API baselines are {actual_baselines}", file=sys.stderr)
    raise SystemExit(1)

codes = set()
code_locations: dict[str, list[str]] = {}
for path in (root / "Sources/InnoRouterMacrosPlugin").glob("*.swift"):
    for code in re.findall(r"InnoRouterMacro\.[EW]\d{3}", path.read_text()):
        codes.add(code)
        code_locations.setdefault(code, []).append(path.name)
duplicates = {code: paths for code, paths in code_locations.items() if len(paths) > 1}
if duplicates:
    print("[check-docs-consistency] Failed: duplicate macro diagnostic codes", file=sys.stderr)
    for code, paths in sorted(duplicates.items()):
        print(f"  {code}: {', '.join(paths)}", file=sys.stderr)
    raise SystemExit(1)
catalog = (root / "Sources/InnoRouterMacros/InnoRouterMacros.docc/Macro-Diagnostics.md").read_text()
documented = set(re.findall(r"^\| \x60(InnoRouterMacro\.[EW]\d{3})\x60 \|", catalog, re.MULTILINE))
if codes != documented:
    print("[check-docs-consistency] Failed: macro diagnostic catalog drift", file=sys.stderr)
    print(f"  source only: {sorted(codes - documented)}", file=sys.stderr)
    print(f"  docs only: {sorted(documented - codes)}", file=sys.stderr)
    raise SystemExit(1)
PY

RETIRED="NavigationStore|ModalStore|FlowStore|AppShellStore|AdaptiveSplitStore|SceneStore|NavigationIntent|ModalIntent|FlowIntent|NavigationPlan|FlowPlan|ChildCoordinator"
ENTRY_DOCS=(
  AGENTS.md
  CLAUDE.md
  CONTRIBUTING.md
  Examples/README.md
  ExamplesSmoke/README.md
  Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/InnoRouterSwiftUI.md
  Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/InnoRouterDeepLink.md
  Sources/InnoRouterMacros/InnoRouterMacros.docc/Router-Macro-First.md
  Sources/InnoRouterTesting/InnoRouterTesting.docc/InnoRouterTesting.md
)
for path in "${ENTRY_DOCS[@]}"; do
  reject_pattern "$path" "$RETIRED" "$path advertises a retired 5.x authority"
done

[[ "$failures" -eq 0 ]] || exit 1
echo "[check-docs-consistency] 6.0 public docs and product contract match"
