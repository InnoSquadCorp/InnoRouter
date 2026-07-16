#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal Markdown and shell snippets are search patterns.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROADMAP_PATH="$ROOT_DIR/Docs/competitive-analysis-and-roadmap.md"
README_PATH="$ROOT_DIR/README.md"
README_KO_PATH="$ROOT_DIR/README.ko.md"
README_DE_PATH="$ROOT_DIR/README.de.md"
README_ES_PATH="$ROOT_DIR/README.es.md"
README_JA_PATH="$ROOT_DIR/README.ja.md"
README_RU_PATH="$ROOT_DIR/README.ru.md"
README_ZH_HANS_PATH="$ROOT_DIR/README.zh-Hans.md"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
REJECTION_CATALOG_PATH="$ROOT_DIR/Sources/InnoRouterCore/InnoRouterCore.docc/Articles/Rejection-Reasons.md"
MACRO_CONTRACT_PATH="$ROOT_DIR/Docs/design-macro-first-surfaces.md"
MACRO_DIAGNOSTIC_PATH="$ROOT_DIR/Sources/InnoRouterMacros/InnoRouterMacros.docc/Macro-Diagnostics.md"
SPATIAL_TUTORIAL_PATH="$ROOT_DIR/Sources/InnoRouterSpatial/InnoRouterSpatial.docc/Articles/Tutorial-VisionOSScenes.md"

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

check_absent_match() {
  local file_path="$1"
  local pattern="$2"
  local message="$3"

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi

  if grep -E -- "$pattern" "$file_path" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $message" >&2
    grep -En -- "$pattern" "$file_path" >&2
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

check_match() {
  local file_path="$1"
  local pattern="$2"
  local message="$3"

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi

  if ! grep -E -- "$pattern" "$file_path" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $message" >&2
    failures=1
  fi
}

markdown_section() {
  local file_path="$1"
  local start_heading="$2"
  local end_heading="$3"

  awk -v start="$start_heading" -v end="$end_heading" '
    $0 == start { in_section = 1; found = 1 }
    $0 == end && in_section { end_found = 1; exit }
    in_section { print }
    END { if (!found || !end_found) exit 1 }
  ' "$file_path"
}

check_section_match() {
  local file_path="$1"
  local start_heading="$2"
  local end_heading="$3"
  local pattern="$4"
  local message="$5"
  local section

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi
  if ! section="$(markdown_section "$file_path" "$start_heading" "$end_heading")"; then
    echo "[check-docs-consistency] Failed: $(basename "$file_path") has no complete $start_heading section" >&2
    failures=1
    return
  fi
  if ! grep -E -- "$pattern" <<< "$section" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: $message" >&2
    failures=1
  fi
}

check_section_line_match() {
  local file_path="$1"
  local start_heading="$2"
  local end_heading="$3"
  local literal="$4"
  local pattern="$5"
  local message="$6"
  local section
  local matching_lines

  if [[ ! -f "$file_path" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $file_path" >&2
    failures=1
    return
  fi
  if ! section="$(markdown_section "$file_path" "$start_heading" "$end_heading")"; then
    echo "[check-docs-consistency] Failed: $(basename "$file_path") has no complete $start_heading section" >&2
    failures=1
    return
  fi
  matching_lines="$(grep -F -- "$literal" <<< "$section" || true)"
  if [[ -z "$matching_lines" ]] || \
    ! grep -E -- "$pattern" <<< "$matching_lines" >/dev/null 2>&1; then
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

check_macro_diagnostic_codes_documented() {
  local source_directory="$ROOT_DIR/Sources/InnoRouterMacrosPlugin"

  if [[ ! -d "$source_directory" ]]; then
    echo "[check-docs-consistency] Failed: required directory not found: $source_directory" >&2
    failures=1
    return
  fi
  if [[ ! -f "$MACRO_DIAGNOSTIC_PATH" ]]; then
    echo "[check-docs-consistency] Failed: required file not found: $MACRO_DIAGNOSTIC_PATH" >&2
    failures=1
    return
  fi

  local source_definitions
  local source_mentions
  local catalog_rows
  local source_codes
  local documented_codes
  source_definitions="$(
    { rg --no-filename --only-matching 'return "InnoRouterMacro\.[EW][0-9]{3}"' \
      "$source_directory" -g '*.swift' || true; } |
      sed -E 's/^return "(InnoRouterMacro\.[EW][0-9]{3})"$/\1/'
  )"
  source_mentions="$(
    { rg --no-filename --only-matching 'InnoRouterMacro\.[EW][0-9]{3}' \
      "$source_directory" -g '*.swift' || true; } | sort -u
  )"
  catalog_rows="$(
    { rg --no-filename '^\| `InnoRouterMacro\.[EW][0-9]{3}` \| (Error|Warning) \| [^|]*[^|[:space:]][^|]* \|$' \
      "$MACRO_DIAGNOSTIC_PATH" || true; }
  )"
  source_codes="$(printf '%s\n' "$source_definitions" | sort -u)"
  documented_codes="$(
    printf '%s\n' "$catalog_rows" |
      sed -E 's/^\| `(InnoRouterMacro\.[EW][0-9]{3})` \|.*$/\1/' |
      sort -u
  )"

  if [[ -z "$source_codes" ]]; then
    echo "[check-docs-consistency] Failed: no macro diagnostic codes found in $source_directory" >&2
    failures=1
    return
  fi
  if [[ "$source_mentions" != "$source_codes" ]]; then
    echo "[check-docs-consistency] Failed: macro diagnostic codes must use canonical return definitions" >&2
    failures=1
  fi

  local duplicate_source_codes
  local duplicate_documented_codes
  duplicate_source_codes="$(printf '%s\n' "$source_definitions" | sort | uniq -d)"
  duplicate_documented_codes="$(
    printf '%s\n' "$catalog_rows" |
      sed -E 's/^\| `(InnoRouterMacro\.[EW][0-9]{3})` \|.*$/\1/' |
      sort | uniq -d
  )"
  if [[ -n "$duplicate_source_codes" ]]; then
    echo "[check-docs-consistency] Failed: macro diagnostic codes have duplicate source definitions:" >&2
    printf '%s\n' "$duplicate_source_codes" | sed 's/^/[check-docs-consistency]   /' >&2
    failures=1
  fi
  if [[ -n "$duplicate_documented_codes" ]]; then
    echo "[check-docs-consistency] Failed: macro diagnostic catalog has duplicate recovery rows:" >&2
    printf '%s\n' "$duplicate_documented_codes" | sed 's/^/[check-docs-consistency]   /' >&2
    failures=1
  fi

  if grep -E '^\| `InnoRouterMacro\.E[0-9]{3}` \| Warning \|' <<< "$catalog_rows" >/dev/null 2>&1 ||
    grep -E '^\| `InnoRouterMacro\.W[0-9]{3}` \| Error \|' <<< "$catalog_rows" >/dev/null 2>&1; then
    echo "[check-docs-consistency] Failed: macro diagnostic catalog severity does not match its E/W code" >&2
    failures=1
  fi

  local missing_codes
  local stale_codes
  missing_codes="$(comm -23 \
    <(printf '%s\n' "$source_codes") \
    <(printf '%s\n' "$documented_codes"))"
  stale_codes="$(comm -13 \
    <(printf '%s\n' "$source_codes") \
    <(printf '%s\n' "$documented_codes"))"

  if [[ -n "$missing_codes" ]]; then
    echo "[check-docs-consistency] Failed: macro diagnostic catalog is missing source codes:" >&2
    printf '%s\n' "$missing_codes" | sed 's/^/[check-docs-consistency]   /' >&2
    failures=1
  fi
  if [[ -n "$stale_codes" ]]; then
    echo "[check-docs-consistency] Failed: macro diagnostic catalog contains stale codes:" >&2
    printf '%s\n' "$stale_codes" | sed 's/^/[check-docs-consistency]   /' >&2
    failures=1
  fi
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

echo "[check-docs-consistency] Checking macro-first surface contract"
readme_contracts=(
  "$README_PATH|## 30-second quick start|## OSS release and SemVer contract|## Choosing the right surface|## Documentation|^Start with a route enum and a macro-first host\.|,[[:space:]]|,[[:space:]]or[[:space:]]|## Installation"
  "$README_KO_PATH|## 30초 Quick Start|## OSS 릴리즈 및 SemVer 계약|## 적합한 surface 고르기|## 문서|^route enum과 macro-first host로 시작하세요\.|,[[:space:]]|,[[:space:]]또는[[:space:]]|## 설치"
  "$README_DE_PATH|## 30-Sekunden-Schnellstart|## OSS-Release- und SemVer-Vertrag|## Die richtige Oberfläche wählen|## Dokumentation|^Beginnen Sie mit einem Route-Enum und einem macro-first Host\.|,[[:space:]]|[[:space:]]oder[[:space:]]|## Installation"
  "$README_ES_PATH|## Inicio rápido en 30 segundos|## Contrato de release OSS y SemVer|## Eligiendo la superficie correcta|## Documentación|^Empiece con un enum de rutas y un host macro-first\.|,[[:space:]]|[[:space:]]o[[:space:]]|## Instalación"
  "$README_JA_PATH|## 30 秒クイックスタート|## OSS リリースと SemVer 契約|## 適切な surface を選ぶ|## ドキュメント|^まず route enum と macro-first host から始めます。|、|、または[[:space:]]|## インストール"
  "$README_RU_PATH|## Быстрый старт за 30 секунд|## Контракт OSS-релиза и SemVer|## Выбор правильной поверхности|## Документация|^Начинайте с route enum и macro-first host\.|,[[:space:]]|[[:space:]]или[[:space:]]|## Установка"
  "$README_ZH_HANS_PATH|## 30 秒快速开始|## OSS 发布与 SemVer 合约|## 选择正确的表面|## 文档|^从 route enum 和 macro-first host 开始。|、|[[:space:]]或[[:space:]]|## 安装"
)
for contract in "${readme_contracts[@]}"; do
  IFS='|' read -r readme_path quick_start_heading quick_start_end \
    selection_heading selection_end selection_lead first_host_separator \
    final_host_separator installation_heading <<< "$contract"

  check_section_match "$readme_path" "$installation_heading" "$quick_start_heading" \
    '^[[:space:]]*\.package\(url: "https://github\.com/InnoSquadCorp/InnoRouter\.git", from: "5\.0\.0"\)' \
    "$(basename "$readme_path") installation does not use the canonical package dependency"
  check_section_match "$readme_path" "$installation_heading" "$quick_start_heading" \
    '^[[:space:]]*\.product\(name: "InnoRouter", package: "InnoRouter"\)' \
    "$(basename "$readme_path") installation does not attach InnoRouter to an app target"

  check_section_match "$readme_path" "$quick_start_heading" "$quick_start_end" \
    '^@Router$' \
    "$(basename "$readme_path") quick start has no standalone @Router declaration"
  check_section_match "$readme_path" "$quick_start_heading" "$quick_start_end" \
    '^[[:space:]]*RouterHost\(' \
    "$(basename "$readme_path") quick start does not install RouterHost"
  check_section_match "$readme_path" "$quick_start_heading" "$quick_start_end" \
    '^[[:space:]]*@EnvironmentRouter\(' \
    "$(basename "$readme_path") quick start does not read @EnvironmentRouter"
  check_section_match "$readme_path" "$quick_start_heading" "$quick_start_end" \
    '`@EnvironmentSceneRouter`' \
    "$(basename "$readme_path") quick start does not route spatial actions through @EnvironmentSceneRouter"

  check_section_match "$readme_path" "$selection_heading" "$selection_end" \
    "$selection_lead" \
    "$(basename "$readme_path") selection guide no longer leads with macro-first routing"
  selection_rows=(
    '^\| [^|]+ \| `@Router` \+ `RouterHost` \|$'
    '^\| [^|]+ \| `@Router` \+ `RouterModalHost` \|$'
    '^\| [^|]+ \| `@Router` \+ `RouterSplitHost` \|$'
    '^\| [^|]+ \| `@Router` \+ `@TabItem` \+ `RouterTabHost` \|$'
    '^\| [^|]+ \| `@Router\(deepLinkSchemes:deepLinkHosts:\)` \+ `@DeepLink` \+ `RouterHost`'"${first_host_separator}"'`RouterSplitHost`'"${final_host_separator}"'`RouterTabHost` \|$'
    '^\| [^|]+ \| `InnoRouterSpatial`:[[:space:]]*`@SceneRouter` \+ `@Scene` \+ `<Route>\.scenes` \|$'
  )
  for row_pattern in "${selection_rows[@]}"; do
    check_section_match "$readme_path" "$selection_heading" "$selection_end" \
      "$row_pattern" \
      "$(basename "$readme_path") selection table is missing a canonical macro-first surface row"
  done

  check_match "$readme_path" \
    '^\| \[Tutorial-VisionOSScenes\]\(Sources/InnoRouterSpatial/InnoRouterSpatial\.docc/Articles/Tutorial-VisionOSScenes\.md\) \| `InnoRouterSpatial` \| [^|]*`@SceneRouter`[^|]*`@Scene`[^|]* \|$' \
    "$(basename "$readme_path") has a stale Spatial tutorial link, product, or Store-first description"
done


examples_contracts=(
  "$README_PATH|## Docs and release flow|## Quality gates|explicit Store / Coordinator escalation|Advanced"
  "$README_KO_PATH|## 문서와 릴리즈 흐름|## Quality 게이트|명시적인 Store / Coordinator 확장 경로|고급"
  "$README_DE_PATH|## Docs- und Release-Flow|## Quality-Gates|explizite Store- / Coordinator-Eskalation|Fortgeschritten"
  "$README_ES_PATH|## Documentos y flujo de release|## Puertas de calidad|escalamiento explícito a Store / Coordinator|avanzado"
  "$README_JA_PATH|## ドキュメントとリリースフロー|## 品質ゲート|明示的な Store / Coordinator への移行|高度な"
  "$README_RU_PATH|## Docs и flow релиза|## Шлюзы качества|явного перехода к Store / Coordinator|Продвинутый"
  "$README_ZH_HANS_PATH|## 文档和发布流程|## 质量门|显式 Store / Coordinator 升级路径|高级"
)
for contract in "${examples_contracts[@]}"; do
  IFS='|' read -r readme_path examples_overview_end examples_list_end \
    escalation_pattern advanced_label <<< "$contract"

  overview_patterns=(
    "$escalation_pattern"
    'InnoRouterMacroFirstSmoke'
    '`RouterModalHost`'
    '`RouterSplitHost`'
    '`RouterTabHost`'
    '`@SceneRouter`'
  )
  for overview_pattern in "${overview_patterns[@]}"; do
    check_section_match "$readme_path" '## `Examples` vs `ExamplesSmoke`' \
      "$examples_overview_end" "$overview_pattern" \
      "$(basename "$readme_path") examples overview is missing macro-first or advanced coverage"
  done

  check_section_line_match "$readme_path" '## `Examples` vs `ExamplesSmoke`' \
    "$examples_overview_end" 'Examples/MacrosExample.swift' '[Mm]acro-first' \
    "$(basename "$readme_path") examples overview does not classify MacrosExample as macro-first"

  macro_example_paths=(
    Examples/MacrosExample.swift
    Examples/StandaloneExample.swift
    Examples/DeepLinkExample.swift
    Examples/VisionOSImmersiveExample.swift
  )
  for example_path in "${macro_example_paths[@]}"; do
    check_section_line_match "$readme_path" '## Examples' "$examples_list_end" \
      "$example_path" '[Mm]acro-first' \
      "$(basename "$readme_path") does not classify $example_path as macro-first"
  done

  advanced_example_paths=(
    Examples/CoordinatorExample.swift
    Examples/SplitCoordinatorExample.swift
    Examples/AppShellExample.swift
  )
  for example_path in "${advanced_example_paths[@]}"; do
    check_section_line_match "$readme_path" '## Examples' "$examples_list_end" \
      "$example_path" "$advanced_label" \
      "$(basename "$readme_path") does not classify $example_path as advanced"
  done
done

check_absent "$MACRO_CONTRACT_PATH" 'before implementation' \
  "macro-first contract still presents the implemented surface as future work"
check_absent "$MACRO_CONTRACT_PATH" 'skip proposed' \
  "macro-first contract still labels implemented API as proposed"
check_absent "$MACRO_CONTRACT_PATH" 'host: true' \
  "macro-first contract references the nonexistent @Scene host argument"
check_absent "$MACRO_CONTRACT_PATH" 're-exports spatial support' \
  "macro-first contract incorrectly claims the default umbrella re-exports Spatial"
check_absent "$MACRO_CONTRACT_PATH" 'platform adaptation such as cover-to-sheet fallback' \
  "macro-first contract incorrectly promises a runtime diagnostic for normal cover adaptation"
check_present "$MACRO_CONTRACT_PATH" 'every live generated scene participates' \
  "macro-first contract does not document generated Spatial host election"
check_absent "$MACRO_CONTRACT_PATH" 'later cases become lifecycle' \
  "macro-first contract still describes generated Spatial scenes as restricted anchors"
check_present "$MACRO_CONTRACT_PATH" 'does not re-export it' \
  "macro-first contract does not preserve the opt-in Spatial product boundary"
check_present "$MACRO_CONTRACT_PATH" 'It does not emit an error or warning' \
  "macro-first contract does not document silent cover-to-sheet adaptation"
check_present "$MACRO_CONTRACT_PATH" '(`E028`)' \
  "macro-first contract does not document unreachable deep-link mappings"
check_present "$MACRO_CONTRACT_PATH" '`W012`' \
  "macro-first contract does not document reachable typed deep-link fallbacks"
check_section_match "$SPATIAL_TUTORIAL_PATH" \
  '## 1. Declare the scene inventory' '## 2. Install the generated scene tree' \
  '^[[:space:]]*\.product\(name: "InnoRouterSpatial", package: "InnoRouter"\)$' \
  "Spatial tutorial does not attach the opt-in InnoRouterSpatial product"
check_absent "$SPATIAL_TUTORIAL_PATH" \
  '.product(name: "InnoRouter", package: "InnoRouter")' \
  "Spatial tutorial adds the default umbrella despite documenting a Spatial-only target"
check_section_match "$SPATIAL_TUTORIAL_PATH" \
  '## 1. Declare the scene inventory' '## 2. Install the generated scene tree' \
  '^[[:space:]]*import InnoRouterSpatial[[:space:]]*$' \
  "Spatial tutorial does not import the product it asks consumers to add"
check_absent_match "$SPATIAL_TUTORIAL_PATH" '^[[:space:]]*import InnoRouter[[:space:]]*$' \
  "Spatial tutorial imports InnoRouter without adding the default umbrella product"
check_macro_diagnostic_codes_documented

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

workflow_toolchain_expectations=(
  'principle-gates.yml:1'
  'platforms.yml:2'
  'release.yml:1'
  'docs-ci.yml:1'
  'coverage.yml:1'
  'performance-smoke.yml:1'
)
for expectation in "${workflow_toolchain_expectations[@]}"; do
  workflow_name="${expectation%%:*}"
  expected_count="${expectation##*:}"
  workflow_path="$ROOT_DIR/.github/workflows/$workflow_name"
  xcode_pin_count="$(grep -Fc 'xcode-version: "26.6"' "$workflow_path" || true)"
  runner_count="$(grep -Ec '^[[:space:]]+runs-on: macos-26$' "$workflow_path" || true)"
  if [[ "$xcode_pin_count" != "$expected_count" ]]; then
    echo "[check-docs-consistency] Failed: $workflow_name must pin Xcode 26.6 exactly $expected_count time(s)" >&2
    failures=1
  fi
  if [[ "$runner_count" != "$expected_count" ]]; then
    echo "[check-docs-consistency] Failed: $workflow_name must use macos-26 exactly $expected_count time(s)" >&2
    failures=1
  fi
done

check_present "$ROOT_DIR/RELEASING.md" '**macos-26**' \
  "RELEASING.md does not document the compiling runner image"
check_present "$ROOT_DIR/RELEASING.md" '**26.6**' \
  "RELEASING.md does not document the pinned Xcode version"

check_absent "$ROOT_DIR/.github/workflows/platforms.yml" \
  'Swift 6.2 is the floor' \
  "platform workflow still documents the old Swift floor"
check_present "$ROOT_DIR/.cursor/rules/innoflow-framework.mdc" \
  'Swift 6.3+.' \
  "framework rule does not match the package Swift floor"
check_absent "$ROOT_DIR/RELEASING.md" \
  'Linux CI builds the plugin' \
  "RELEASING.md claims a Linux CI job that does not exist"
check_absent "$ROOT_DIR/RELEASING.md" \
  'Linux CI may import' \
  "RELEASING.md claims a Linux CI job that does not exist"

public_products=(
  InnoRouter
  InnoRouterCore
  InnoRouterSwiftUI
  InnoRouterSpatial
  InnoRouterDeepLink
  InnoRouterEffects
  InnoRouterMacros
  InnoRouterTesting
)
for product in "${public_products[@]}"; do
  check_present "$ROOT_DIR/.github/workflows/platforms.yml" \
    "-scheme $product" \
    "platform workflow does not compile $product explicitly"
  check_present "$ROOT_DIR/scripts/principle-gates.sh" \
    "-scheme $product" \
    "local platform probe does not compile $product"
done

echo "[check-docs-consistency] Checking current major-version contract"
for readme_path in "$ROOT_DIR"/README*.md; do
  check_present "$readme_path" '5.x' \
    "$(basename "$readme_path") does not describe the 5.x compatibility line"
  check_present "$readme_path" '`6.0.0`' \
    "$(basename "$readme_path") does not reserve breaking changes for 6.0.0"
  check_present "$readme_path" '5.0.0-rc.1' \
    "$(basename "$readme_path") does not use a current pre-release example"
  check_present "$readme_path" 'prerelease=true' \
    "$(basename "$readme_path") does not document manual pre-release publication"
  check_absent "$readme_path" '^[0-9]+\.[0-9]+\.[0-9]+$' \
    "$(basename "$readme_path") still describes the removed GA-only regex"
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
check_present "$ROOT_DIR/scripts/resolve-release-metadata.sh" \
  'release-version-policy.py' \
  "release metadata does not use the shared release-version policy"
check_present "$ROOT_DIR/scripts/resolve-docc-source-ref.sh" \
  'release-version-policy.py' \
  "DocC source refs do not use the shared release-version policy"
check_present "$ROOT_DIR/scripts/build-docc-site.sh" \
  'resolve-docc-source-ref.sh' \
  "DocC builder does not delegate source-ref selection to the tested resolver"
check_present "$ROOT_DIR/scripts/build-docc-site.sh" \
  'resolve-latest-publication.sh' \
  "DocC builder does not prevent /latest/ from moving to an older GA"
check_present "$ROOT_DIR/.github/workflows/release.yml" \
  'resolve-latest-publication.sh' \
  "release workflow does not share the tested latest-publication policy"
check_present "$ROOT_DIR/.github/workflows/principle-gates.yml" \
  'test-resolve-latest-publication.sh' \
  "principle-gates workflow does not test latest-publication scenarios"
check_present "$ROOT_DIR/scripts/build-docc-site.sh" \
  'sort-published' \
  "DocC portal does not sort releases with the shared SemVer policy"
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
check_present "$ROOT_DIR/.github/workflows/principle-gates.yml" \
  'actionlint -config-file .github/actionlint.yaml' \
  "principle-gates workflow does not run actionlint"
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
