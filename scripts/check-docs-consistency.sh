#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROADMAP_PATH="$ROOT_DIR/Docs/competitive-analysis-and-roadmap.md"
README_PATH="$ROOT_DIR/README.md"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
REJECTION_CATALOG_PATH="$ROOT_DIR/Sources/InnoRouterCore/InnoRouterCore.docc/Articles/Rejection-Reasons.md"

failures=0

check_absent() {
  local file_path="$1"
  local pattern="$2"
  local message="$3"

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi

  if grep -Fn -- "$pattern" "$file_path" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $message" >&2
    grep -Fn -- "$pattern" "$file_path" >&2
    failures=1
  fi
}

check_present() {
  local file_path="$1"
  local pattern="$2"
  local message="$3"

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi

  if ! grep -F -- "$pattern" "$file_path" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $message" >&2
    failures=1
  fi
}

check_enum_cases_documented() {
  local source_path="$1"
  local enum_name="$2"

  if [[ ! -f "$source_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $source_path" >&2
    failures=1
    return
  fi

  if [[ ! -f "$REJECTION_CATALOG_PATH" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $REJECTION_CATALOG_PATH" >&2
    failures=1
    return
  fi

  local enum_cases
  enum_cases="$(
    sed -n "/public enum ${enum_name}/,/^}/p" "$source_path" |
      sed -nE 's/^[[:space:]]*case ([A-Za-z_][A-Za-z0-9_]*).*/\1/p' |
      sort -u
  )"
  local catalog_section
  catalog_section="$(
    sed -n "/^### .*${enum_name}/,/^## /p" "$REJECTION_CATALOG_PATH"
  )"

  if [[ -z "$enum_cases" ]]; then
    echo "[check-docs-consistency] Failed: no cases found for $enum_name in $source_path" >&2
    failures=1
    return
  fi
  if [[ -z "$catalog_section" ]]; then
    echo "[check-docs-consistency] Failed: rejection catalog has no ${enum_name} section" >&2
    failures=1
    return
  fi

  while IFS= read -r case_name; do
    if ! grep -F "\`.${case_name}" <<< "$catalog_section" >/dev/null 2>&1; then
      echo "[check-docs-consistency] Failed: rejection catalog omits ${enum_name}.${case_name}" >&2
      failures=1
    fi
  done <<< "$enum_cases"
}

echo "[check-docs-consistency] Checking known roadmap drift claims"
check_absent "$ROADMAP_PATH" 'Remaining gap: `RouteStep` / `FlowPlan` are not yet' \
  "roadmap still claims RouteStep / FlowPlan are not Codable"
check_absent "$ROADMAP_PATH" 'state restoration still requires hand-rolling a plan.' \
  "roadmap still claims flow state restoration requires manual planning"
check_absent "$ROADMAP_PATH" 'requires hand-rolling commands.' \
  "roadmap still claims multi-step deep-link rehydration needs hand-rolled commands"
check_absent "$ROADMAP_PATH" '`FlowIntent` parallels were intentionally skipped' \
  "roadmap still claims FlowIntent ergonomic parity was skipped entirely"
check_absent "$ROADMAP_PATH" '| P2 | UIKit escape hatch | adoption path | large | open |' \
  "roadmap still marks the UIKit escape hatch as open"
check_absent "$README_PATH" 'Separate product decision' \
  "README still claims the UIKit escape hatch needs a product decision"
check_absent "$CHANGELOG_PATH" 'awaiting product decision' \
  "changelog still claims the UIKit escape hatch is awaiting product decision"
check_absent "$CHANGELOG_PATH" 'remains open behind' \
  "changelog still claims the UIKit escape hatch remains open"
check_absent "$ROADMAP_PATH" '3.0.0 release candidate' \
  "roadmap still claims 3.0.0 is the release candidate"
check_absent "$ROADMAP_PATH" 'debounce deferred' \
  "roadmap still claims debounce remains deferred"
check_absent "$ROADMAP_PATH" '.debounce remains open' \
  "roadmap still claims debounce remains open"
check_absent "$ROADMAP_PATH" 'Next gap is P3-4' \
  "roadmap still contains stale next-gap positioning"
check_absent "$CHANGELOG_PATH" '### Deferred to 4.1' \
  "changelog still has a 4.1 deferred section after the 4.0 release sweep"
check_absent "$README_PATH" 'deferred from P3-4' \
  "README still claims debounce is deferred from P3-4"

echo "[check-docs-consistency] Checking Swift toolchain contract"
if [[ "$(head -n 1 "$ROOT_DIR/Package.swift")" != '// swift-tools-version: 6.3' ]]; then
  echo "[check-docs-consistency] Failed: Package.swift must declare the Swift 6.3 floor" >&2
  failures=1
fi

for readme_path in "$ROOT_DIR"/README*.md; do
  check_present "$readme_path" 'Swift 6.3+' \
    "$(basename "$readme_path") does not declare Swift 6.3+"
  check_present "$readme_path" 'swift-tools-version: 6.3' \
    "$(basename "$readme_path") does not match Package.swift's tools version"
done

check_present "$ROOT_DIR/AGENTS.md" 'Swift 6.3+' \
  "AGENTS.md does not match the package Swift floor"
check_present "$ROOT_DIR/CLAUDE.md" 'Swift 6.3+' \
  "CLAUDE.md does not match the package Swift floor"
check_present "$ROOT_DIR/RELEASING.md" 'swift-tools-version: 6.3' \
  "RELEASING.md does not match the package Swift floor"
check_present "$ROOT_DIR/scripts/check-docs-code-blocks.sh" '// swift-tools-version: 6.3' \
  "documentation snippet package does not match the package Swift floor"
check_present "$ROOT_DIR/scripts/check-public-api.sh" 'same Swift 6.3 toolchain used by CI' \
  "public API guidance does not match the CI Swift line"
check_present "$ROADMAP_PATH" 'iOS 18 / Swift 6.3' \
  "roadmap does not match the package Swift floor"

swift_syntax_series="$(
  sed -nE 's/.*\.upToNextMinor\(from: "([0-9]{3})\.[^"]+"\).*/\1/p' \
    "$ROOT_DIR/Package.swift" | head -n 1
)"
if [[ "$swift_syntax_series" != '603' ]]; then
  echo "[check-docs-consistency] Failed: Swift 6.3 floor must stay aligned with swift-syntax 603.x" >&2
  failures=1
fi

echo "[check-docs-consistency] Checking current major-version contract"
for readme_path in "$ROOT_DIR"/README*.md; do
  check_present "$readme_path" '5.x' \
    "$(basename "$readme_path") does not describe the 5.x compatibility line"
  check_present "$readme_path" '`6.0.0`' \
    "$(basename "$readme_path") does not reserve breaking changes for 6.0.0"
  check_present "$readme_path" '5.0.0-rc.1' \
    "$(basename "$readme_path") does not use a current pre-release example"
  check_absent "$readme_path" '4.1.0-rc.1' \
    "$(basename "$readme_path") still uses a 4.x pre-release example"
  check_absent "$readme_path" '4.2.0-beta.2' \
    "$(basename "$readme_path") still uses a 4.x beta example"
  check_absent "$readme_path" 'release-4.1.0' \
    "$(basename "$readme_path") still uses a 4.x invalid-tag example"
done

check_present "$ROOT_DIR/RELEASING.md" 'InnoRouter 5.x follows' \
  "RELEASING.md does not describe the current 5.x line"
check_present "$ROOT_DIR/RELEASING.md" 'goes to a `6.0.0` cycle' \
  "RELEASING.md does not reserve breaking work for 6.0.0"
check_present "$ROOT_DIR/CONTRIBUTING.md" \
  'Breaking changes target a 6.0 cycle, not a 5.x minor.' \
  "CONTRIBUTING.md does not match the 5.x compatibility policy"
check_present "$ROOT_DIR/SECURITY.md" '| Latest major release line | active | yes |' \
  "SECURITY.md does not define the supported line without stale version numbers"
check_present "$ROOT_DIR/SECURITY.md" 'latest supported release' \
  "SECURITY.md still hard-codes a stale security-patch line"
check_present "$ROOT_DIR/.github/workflows/release.yml" \
  'for example 5.0.0-rc.1' \
  "release workflow does not use a current pre-release example"
check_present "$ROOT_DIR/Docs/CI-gates.md" 'bare semver (`5.0.0`)' \
  "CI guide does not use a current release-tag example"
check_present "$ROOT_DIR/scripts/check-changelog-sync.sh" \
  'BASE_REF=origin/release/5.x' \
  "changelog gate guidance does not use the current release branch"
check_present "$ROOT_DIR/scripts/check-changelog-sync.sh" \
  'actions/checkout@v7' \
  "changelog gate guidance does not match the workflow action version"
check_absent \
  "$ROOT_DIR/Sources/InnoRouterMacros/InnoRouterMacros.docc/Articles/Guide-MacroVisibility.md" \
  'v4.x roadmap' \
  "macro visibility guide still presents an abandoned 4.x roadmap item"
check_absent "$ROOT_DIR/.swiftlint.yml" '4.1.x store split' \
  "SwiftLint configuration still describes a completed 4.1.x plan"

echo "[check-docs-consistency] Checking changelog contribution contract"
if [[ -e "$ROOT_DIR/.changes" ]]; then
  echo "[check-docs-consistency] Failed: obsolete .changes fragment directory still exists" >&2
  failures=1
fi
check_absent "$ROOT_DIR/CONTRIBUTING.md" '.changes/' \
  "CONTRIBUTING.md still requires changelog fragments"
check_present "$ROOT_DIR/CONTRIBUTING.md" \
  'Add the user-visible impact to `CHANGELOG.md` under `## Unreleased`' \
  "CONTRIBUTING.md does not require direct Unreleased entries"
check_present "$ROOT_DIR/RELEASING.md" '## Changelog cut' \
  "RELEASING.md does not explain how to cut Unreleased entries"
check_present "$ROOT_DIR/scripts/check-changelog-sync.sh" \
  'git merge-base "$BASE_REF" HEAD' \
  "changelog gate does not compare from the merge base"
check_present "$ROOT_DIR/scripts/check-changelog-sync.sh" \
  'extract_unreleased' \
  "changelog gate does not scope comparisons to Unreleased"
check_present "$ROOT_DIR/.github/workflows/principle-gates.yml" \
  'github.event.pull_request.base.sha || github.event.before' \
  "changelog workflow does not select the real PR/push base SHA"
check_present "$ROOT_DIR/.github/workflows/principle-gates.yml" \
  'Test CHANGELOG sync gate' \
  "changelog workflow does not run its regression scenarios"
check_present "$ROOT_DIR/.github/workflows/principle-gates.yml" \
  'Test release changelog contract' \
  "principle-gates workflow does not test release changelog scenarios"
check_present "$ROOT_DIR/.github/workflows/release.yml" \
  'check-release-changelog.sh' \
  "release workflow does not validate the changelog stored in the tag commit"
check_absent "$ROOT_DIR/.github/workflows/principle-gates.yml" \
  'Swift 6.2 is the floor' \
  "principle-gates workflow still documents the old Swift floor"

echo "[check-docs-consistency] Checking public-product snippet coverage"
check_present "$ROOT_DIR/scripts/check-docs-code-blocks.sh" \
  '.product(name: "InnoRouterEffects", package: "InnoRouter")' \
  "documentation snippet consumer omits the opt-in Effects product"
check_present \
  "$ROOT_DIR/Sources/InnoRouterEffects/InnoRouterEffects.docc/InnoRouterEffects.md" \
  '```swift compile' \
  "Effects documentation does not compile an import/use example"

echo "[check-docs-consistency] Checking DocC source-ref contract"
check_present "$ROOT_DIR/scripts/build-docc-site.sh" \
  'resolve-docc-source-ref.sh' \
  "DocC builder does not delegate source-ref selection to the tested resolver"
if ! bash "$ROOT_DIR/scripts/test-resolve-docc-source-ref.sh"; then
  failures=1
fi

echo "[check-docs-consistency] Checking release-site preservation contract"
check_present "$ROOT_DIR/.github/workflows/release.yml" \
  'group: innorouter-release-publish' \
  "release workflows do not share one publishing concurrency group"
check_present "$ROOT_DIR/.github/workflows/release.yml" 'queue: max' \
  "release workflow does not queue concurrent publishing attempts"
check_present "$ROOT_DIR/.github/actionlint.yaml" \
  'unexpected key "queue" for "concurrency" section' \
  "actionlint does not scope its temporary queue-schema exception"
check_absent "$ROOT_DIR/.github/workflows/release.yml" 'continue-on-error: true' \
  "release workflow still ignores an existing-site checkout failure"
check_present "$ROOT_DIR/.github/workflows/release.yml" \
  'Verify Existing gh-pages Site' \
  "release workflow does not validate the preserved site snapshot"
check_present "$ROOT_DIR/.github/workflows/release.yml" \
  '--existing-site-dir .build/gh-pages-cache' \
  "release workflow can build without merging the existing site"
check_absent "$ROOT_DIR/.github/workflows/release.yml" \
  'if [[ -d ".build/gh-pages-cache"' \
  "release workflow still falls back to a destructive fresh-site build"

echo "[check-docs-consistency] Checking rejection catalog enum coverage"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterCore/NavigationInterception.swift" \
  "NavigationCancellationReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterCore/ModalInterception.swift" \
  "ModalCancellationReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterCore/FlowRejectionReason.swift" \
  "FlowRejectionReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterSpatial/SceneContracts.swift" \
  "SceneRejectionReason"
check_enum_cases_documented \
  "$ROOT_DIR/Sources/InnoRouterDeepLink/DeepLinkPipeline.swift" \
  "DeepLinkRejectionReason"

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "[check-docs-consistency] Known drift-prone claims are up to date"
