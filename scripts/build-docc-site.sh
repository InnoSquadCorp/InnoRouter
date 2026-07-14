#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/docc-site"
EXISTING_SITE_DIR=""
VERSION=""
SKIP_LATEST="false"
REPO_OWNER="InnoSquadCorp"
REPO_NAME="InnoRouter"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"

usage() {
  cat <<'EOF'
Usage: ./scripts/build-docc-site.sh --version <version> [--output-dir <dir>] [--existing-site-dir <dir>] [--skip-latest]

Builds a static DocC site for all public InnoRouter modules.

Options:
  --version <version>           Required. Preview or semantic version label.
  --output-dir <dir>            Optional. Defaults to .build/docc-site
  --existing-site-dir <dir>     Optional. Existing site contents to merge before writing new docs.
  --skip-latest                 Optional. Build only the versioned subtree and leave /latest/ untouched.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --existing-site-dir)
      EXISTING_SITE_DIR="${2:-}"
      shift 2
      ;;
    --skip-latest)
      SKIP_LATEST="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[build-docc-site] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "[build-docc-site] --version is required" >&2
  usage
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "[build-docc-site] xcrun is required" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "[build-docc-site] swift is required" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "[build-docc-site] xcodebuild is required" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[build-docc-site] python3 is required" >&2
  exit 1
fi

die() {
  echo "[build-docc-site] $1" >&2
  exit 1
}

sanitize_version() {
  local candidate="$1"

  [[ -n "$candidate" ]] || die "version must not be empty"
  [[ "$candidate" != *"/"* ]] || die "version must not contain path separators"
  [[ "$candidate" != *".."* ]] || die "version must not contain '..'"
  [[ "$candidate" =~ ^[A-Za-z0-9._-]+$ ]] || die "version contains unsupported characters"
}

resolve_path_under_root() {
  local input="$1"
  local absolute_input=""
  local parent=""
  local basename_input=""
  local resolved_parent=""

  [[ -n "$input" ]] || die "path must not be empty"

  if [[ "$input" = /* ]]; then
    absolute_input="$input"
  else
    absolute_input="$ROOT_DIR/$input"
  fi

  parent="$(dirname "$absolute_input")"
  basename_input="$(basename "$absolute_input")"
  mkdir -p "$parent"
  resolved_parent="$(cd "$parent" && pwd -P)"

  case "$resolved_parent/$basename_input" in
    "$ROOT_DIR"/*) printf '%s\n' "$resolved_parent/$basename_input" ;;
    *) die "path must stay within repository root: $input" ;;
  esac
}

resolve_existing_dir_under_root() {
  local input="$1"
  local absolute_input=""
  local resolved=""

  [[ -n "$input" ]] || die "existing site path must not be empty"

  if [[ "$input" = /* ]]; then
    absolute_input="$input"
  else
    absolute_input="$ROOT_DIR/$input"
  fi

  [[ -d "$absolute_input" ]] || die "existing site path does not exist: $input"
  resolved="$(cd "$absolute_input" && pwd -P)"

  case "$resolved" in
    "$ROOT_DIR"/*) printf '%s\n' "$resolved" ;;
    *) die "existing site path must stay within repository root: $input" ;;
  esac
}

sanitize_version "$VERSION"
OUTPUT_DIR="$(resolve_path_under_root "$OUTPUT_DIR")"
if [[ -n "$EXISTING_SITE_DIR" ]]; then
  EXISTING_SITE_DIR="$(resolve_existing_dir_under_root "$EXISTING_SITE_DIR")"
fi

PREVIEW_SOURCE_REF="${GITHUB_SHA:-}"
if [[ "$VERSION" == "preview" ]]; then
  if [[ -z "$PREVIEW_SOURCE_REF" ]] && git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    PREVIEW_SOURCE_REF="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  fi
fi
SOURCE_REF="$(bash "$ROOT_DIR/scripts/resolve-docc-source-ref.sh" "$VERSION" "$PREVIEW_SOURCE_REF")"

DOCC_MODULES=(
  "InnoRouterCore|Sources/InnoRouterCore/InnoRouterCore.docc|core|InnoRouterCore|com.innosquad.innorouter.docs.core"
  "InnoRouterSwiftUI|Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc|swiftui|InnoRouterSwiftUI|com.innosquad.innorouter.docs.swiftui"
  "InnoRouterSpatial|Sources/InnoRouterSpatial/InnoRouterSpatial.docc|spatial|InnoRouterSpatial|com.innosquad.innorouter.docs.spatial"
  "InnoRouterDeepLink|Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc|deeplink|InnoRouterDeepLink|com.innosquad.innorouter.docs.deeplink"
  "InnoRouterEffects|Sources/InnoRouterEffects/InnoRouterEffects.docc|effects|InnoRouterEffects|com.innosquad.innorouter.docs.effects"
  "InnoRouterMacros|Sources/InnoRouterMacros/InnoRouterMacros.docc|macros|InnoRouterMacros|com.innosquad.innorouter.docs.macros"
  "InnoRouterTesting|Sources/InnoRouterTesting/InnoRouterTesting.docc|testing|InnoRouterTesting|com.innosquad.innorouter.docs.testing"
)

SYMBOL_GRAPH_MODULES=(
  "InnoRouter"
  "InnoRouterCore"
  "InnoRouterSwiftUI"
  "InnoRouterSpatial"
  "InnoRouterDeepLink"
  "InnoRouterEffects"
  "InnoRouterMacros"
  "InnoRouterTesting"
)

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-docc.XXXXXX")"
build_log="$(mktemp "${TMPDIR:-/tmp}/innorouter-docc-log.XXXXXX")"
build_bin_dir=""
modules_dir=""
module_cache_dir=""
target_triple=""
resource_dir=""
sdk_path=""
toolchain_bin_dir=""
swift_symbolgraph_extract_bin=""
docc_bin=""
xr_derived_data_dir="$temp_root/xros-derived-data"
xr_modules_dir=""
xr_module_cache_dir=""
xr_sdk_path=""
xr_target_triple="arm64-apple-xros2.0-simulator"
xr_resource_dir=""

cleanup() {
  rm -rf "$temp_root"
  rm -f "$build_log"
}
trap cleanup EXIT

exec 3>&1 4>&2
exec > >(tee "$build_log") 2>&1

echo "[build-docc-site] Preparing output directory: $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ -n "$EXISTING_SITE_DIR" && -d "$EXISTING_SITE_DIR" ]]; then
  echo "[build-docc-site] Merging existing site from $EXISTING_SITE_DIR"
  rsync -a --exclude '.git' "$EXISTING_SITE_DIR"/ "$OUTPUT_DIR"/
fi

if [[ "$SKIP_LATEST" != "true" ]]; then
  if ! latest_policy="$(
    bash "$ROOT_DIR/scripts/resolve-latest-publication.sh" "$VERSION" "$OUTPUT_DIR"
  )"; then
    die "failed to resolve the /latest/ publication policy for $VERSION"
  fi

  latest_action="$(sed -n 's/^action=//p' <<< "$latest_policy")"
  latest_version="$(sed -n 's/^latest_version=//p' <<< "$latest_policy")"
  case "$latest_action" in
    update)
      echo "[build-docc-site] Updating /latest/ to $latest_version"
      ;;
    preserve)
      echo "[build-docc-site] Preserving /latest/ at $latest_version"
      SKIP_LATEST="true"
      ;;
    skip)
      echo "[build-docc-site] Leaving /latest/ unchanged for $VERSION"
      SKIP_LATEST="true"
      ;;
    *)
      die "unexpected /latest/ publication decision: $latest_policy"
      ;;
  esac
fi

rm -rf "${OUTPUT_DIR:?}/${VERSION:?}"
mkdir -p "${OUTPUT_DIR:?}/${VERSION:?}"
if [[ "$SKIP_LATEST" != "true" ]]; then
  rm -rf "${OUTPUT_DIR:?}/latest"
  mkdir -p "${OUTPUT_DIR:?}/latest"
fi

echo "[build-docc-site] Generating symbol graphs"
swift build >/dev/null

echo "[build-docc-site] Building InnoRouterSpatial for visionOS symbols"
xcodebuild build \
  -scheme InnoRouterSpatial \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath "$xr_derived_data_dir" \
  -quiet

build_bin_dir="$(swift build --show-bin-path)"
modules_dir="$build_bin_dir/Modules"
module_cache_dir="$build_bin_dir/ModuleCache"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_platform_path="$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
# Platform frameworks directory holds Testing.framework + its subpackages,
# which InnoRouterTesting imports for Swift Testing integration.
# Resolve it from the active SDK platform when available, but don't fail in
# Command Line Tools-only environments where no Platforms directory exists.
platform_frameworks_dir=""
if [[ -n "$sdk_platform_path" ]]; then
  candidate_platform_frameworks_dir="$sdk_platform_path/Developer/Library/Frameworks"
  if [[ -d "$candidate_platform_frameworks_dir" ]]; then
    platform_frameworks_dir="$candidate_platform_frameworks_dir"
  fi
fi

framework_search_args=()
if [[ -n "$platform_frameworks_dir" ]]; then
  framework_search_args=(-F "$platform_frameworks_dir")
fi

xr_modules_dir="$xr_derived_data_dir/Build/Products/Debug-xrsimulator"
xr_module_cache_dir="$xr_derived_data_dir/ModuleCache.noindex"
xr_sdk_path="$(xcrun --sdk xrsimulator --show-sdk-path)"
xr_sdk_platform_path="$(xcrun --sdk xrsimulator --show-sdk-platform-path 2>/dev/null || true)"
xr_platform_frameworks_dir=""
if [[ -n "$xr_sdk_platform_path" ]]; then
  candidate_xr_platform_frameworks_dir="$xr_sdk_platform_path/Developer/Library/Frameworks"
  if [[ -d "$candidate_xr_platform_frameworks_dir" ]]; then
    xr_platform_frameworks_dir="$candidate_xr_platform_frameworks_dir"
  fi
fi

xros_framework_search_args=()
xr_package_frameworks_dir="$xr_modules_dir/PackageFrameworks"
if [[ -d "$xr_package_frameworks_dir" ]]; then
  xros_framework_search_args+=(-F "$xr_package_frameworks_dir")
fi
if [[ -n "$xr_platform_frameworks_dir" ]]; then
  xros_framework_search_args+=(-F "$xr_platform_frameworks_dir")
fi

[[ -d "$modules_dir" ]] || die "failed to locate build modules directory"
[[ -d "$module_cache_dir" ]] || die "failed to locate module cache directory"
[[ -n "$sdk_path" ]] || die "failed to locate SDK path"
[[ -d "$xr_modules_dir" ]] || die "failed to locate xros build products directory"
[[ -d "$xr_module_cache_dir" ]] || die "failed to locate xros module cache directory"
[[ -n "$xr_sdk_path" ]] || die "failed to locate xrsimulator SDK path"

target_triple="$(swift -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["target"]["triple"])')"
resource_dir="$(swift -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
xr_resource_dir="$(swift -print-target-info -target "$xr_target_triple" | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"

[[ -n "$target_triple" ]] || die "failed to determine target triple"
[[ -n "$resource_dir" ]] || die "failed to determine Swift resource directory"
[[ -n "$xr_resource_dir" ]] || die "failed to determine xros Swift resource directory"

toolchain_bin_dir="$(cd "$(dirname "$(dirname "$resource_dir")")/bin" && pwd -P)"
swift_symbolgraph_extract_bin="$toolchain_bin_dir/swift-symbolgraph-extract"
docc_bin="$toolchain_bin_dir/docc"

[[ -x "$swift_symbolgraph_extract_bin" ]] || die "failed to locate swift-symbolgraph-extract in active toolchain: $swift_symbolgraph_extract_bin"
[[ -x "$docc_bin" ]] || die "failed to locate docc in active toolchain: $docc_bin"

extract_host_module_symbols() {
  local target="$1"
  local output="$2"

  rm -rf "$output"
  mkdir -p "$output"

  "$swift_symbolgraph_extract_bin" \
    -module-name "$target" \
    -I "$modules_dir" \
    "${framework_search_args[@]}" \
    -target "$target_triple" \
    -module-cache-path "$module_cache_dir" \
    -sdk "$sdk_path" \
    -resource-dir "$resource_dir" \
    -minimum-access-level public \
    -omit-extension-block-symbols \
    -output-dir "$output" >/dev/null

  [[ -f "$output/${target}.symbols.json" ]] || die "failed to generate symbol graph for $target"
}

extract_xros_module_symbols() {
  local target="$1"
  local output="$2"

  rm -rf "$output"
  mkdir -p "$output"

  "$swift_symbolgraph_extract_bin" \
    -module-name "$target" \
    -I "$xr_modules_dir" \
    "${xros_framework_search_args[@]}" \
    -target "$xr_target_triple" \
    -module-cache-path "$xr_module_cache_dir" \
    -sdk "$xr_sdk_path" \
    -resource-dir "$xr_resource_dir" \
    -minimum-access-level public \
    -omit-extension-block-symbols \
    -output-dir "$output" >/dev/null

  [[ -f "$output/${target}.symbols.json" ]] || die "failed to generate xros symbol graph for $target"
}

extract_module_symbols() {
  local target="$1"
  local output="$2"

  if [[ "$target" == "InnoRouterSpatial" ]]; then
    extract_xros_module_symbols "$target" "$output"
  else
    extract_host_module_symbols "$target" "$output"
  fi
}

build_module_archive() {
  local target="$1"
  local catalog="$2"
  local output="$3"
  local bundle_id="$4"
  local display_name="$5"
  local hosting_base_path="$6"
  local module_symbols_dir="$7"
  local additional_symbol_graph_args=()
  local duplicate_path="$temp_root/symbol-graphs/$target"
  local index=0

  rm -rf "$output"

  for ((index = 0; index < ${#all_symbol_graph_args[@]}; index += 2)); do
    local flag="${all_symbol_graph_args[index]}"
    local path="${all_symbol_graph_args[index + 1]}"
    if [[ "$path" == "$duplicate_path" ]]; then
      continue
    fi
    additional_symbol_graph_args+=("$flag" "$path")
  done

  "$docc_bin" convert "$ROOT_DIR/$catalog" \
    --additional-symbol-graph-dir "$module_symbols_dir" \
    "${additional_symbol_graph_args[@]}" \
    --output-dir "$output" \
    --fallback-display-name "$display_name" \
    --fallback-bundle-identifier "$bundle_id" \
    --fallback-default-module-kind Framework \
    --checkout-path "$ROOT_DIR" \
    --source-service github \
    --source-service-base-url "$REPO_URL/blob/$SOURCE_REF" \
    --hosting-base-path "$hosting_base_path" \
    --transform-for-static-hosting
}

render_module_entry_redirect() {
  local module_dir="$1"
  local module_name="$2"
  local module_slug=""
  local doc_root_dir=""
  local doc_path=""
  local module_home_path=""

  module_slug="$(printf '%s' "$module_name" | tr '[:upper:]' '[:lower:]')"
  doc_root_dir="$module_dir/documentation/$module_slug"
  doc_path="./documentation/${module_slug}/${module_slug}/"
  module_home_path="$doc_root_dir/$module_slug/index.html"

  [[ -f "$module_home_path" ]] || die "failed to locate DocC module home page: $module_home_path"

  cat >"$module_dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0; url=${doc_path}">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Redirecting…</title>
  <script>window.location.replace('${doc_path}');</script>
</head>
<body>
  <p>Redirecting to <a href="${doc_path}">${module_name}</a>…</p>
</body>
</html>
EOF

  cat >"$doc_root_dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0; url=./${module_slug}/">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Redirecting…</title>
  <script>window.location.replace('./${module_slug}/');</script>
</head>
<body>
  <p>Redirecting to <a href="./${module_slug}/">${module_name}</a>…</p>
</body>
</html>
EOF

  printf '{}\n' >"$module_dir/theme-settings.json"
}

render_version_portal() {
  local page_dir="$1"
  local page_title="$2"

  cat >"$page_dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${page_title} Documentation</title>
  <style>
    :root { color-scheme: light dark; }
    body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; margin: 0; background: #0b1020; color: #e6ebf5; }
    main { max-width: 980px; margin: 0 auto; padding: 48px 24px 64px; }
    h1 { margin: 0 0 12px; font-size: 2.4rem; }
    p { line-height: 1.65; color: #bfd0ea; }
    .grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); margin-top: 28px; }
    .card { display: block; text-decoration: none; color: inherit; border: 1px solid rgba(255,255,255,0.12); border-radius: 18px; padding: 20px; background: rgba(255,255,255,0.04); }
    .card:hover { border-color: rgba(91, 163, 255, 0.75); background: rgba(91, 163, 255, 0.08); }
    .eyebrow { font-size: 0.85rem; letter-spacing: 0.08em; text-transform: uppercase; color: #7ea7ff; }
    .back { display: inline-block; margin-top: 28px; color: #9fc0ff; text-decoration: none; }
  </style>
</head>
<body>
  <main>
    <div class="eyebrow">InnoRouter DocC</div>
    <h1>${page_title}</h1>
    <p>Module-level reference and guides for the current InnoRouter release line.</p>
    <div class="grid">
      <a class="card" href="./core/"><strong>InnoRouterCore</strong><p>Route stack, commands, validators, middleware, batch, and transaction execution.</p></a>
      <a class="card" href="./swiftui/"><strong>InnoRouterSwiftUI</strong><p>Stores, hosts, split layouts, modal routing, coordinators, and environment intent.</p></a>
      <a class="card" href="./spatial/"><strong>InnoRouterSpatial</strong><p>Opt-in visionOS windows, volumes, immersive spaces, scene lifecycle, and ornaments.</p></a>
      <a class="card" href="./deeplink/"><strong>InnoRouterDeepLink</strong><p>Pattern matching, diagnostics, pipelines, and pending deep-link replay.</p></a>
      <a class="card" href="./effects/"><strong>InnoRouterEffects</strong><p>App-boundary navigation and deep-link execution helpers with typed outcomes.</p></a>
      <a class="card" href="./macros/"><strong>InnoRouterMacros</strong><p>@Routable and @CasePathable for concise route declarations and extraction.</p></a>
      <a class="card" href="./testing/"><strong>InnoRouterTesting</strong><p>Host-less assertion test stores for NavigationStore, ModalStore, and FlowStore.</p></a>
    </div>
    <a class="back" href="../">Back to documentation portal</a>
  </main>
</body>
</html>
EOF
}

render_root_portal() {
  local page_path="$1"
  local version_links=""
  local primary_docs_link=""
  local latest_section=""
  local discovered_versions=()

  while IFS= read -r version_dir; do
    discovered_versions+=("$version_dir")
  done < <(
    find "$OUTPUT_DIR" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      ! -name latest \
      -exec basename {} \; |
      python3 "$ROOT_DIR/scripts/release-version-policy.py" sort-published
  )

  for version_dir in "${discovered_versions[@]}"; do
    version_links+="<li><a href=\"./${version_dir}/\">${version_dir}</a></li>"
  done

  if [[ -d "$OUTPUT_DIR/latest" ]]; then
    primary_docs_link='<a class="button primary" href="./latest/">Open latest docs</a>'
    latest_section='
    <section>
      <h2>Latest</h2>
      <p>The <code>latest</code> alias always points at the most recent released documentation set.</p>
      <div class="cta-row">
        <a class="button" href="./latest/">Browse latest</a>
      </div>
    </section>'
  else
    primary_docs_link="<a class=\"button primary\" href=\"./${VERSION}/\">Open ${VERSION} docs</a>"
  fi

  cat >"$page_path" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>InnoRouter Documentation</title>
  <style>
    :root { color-scheme: light dark; }
    body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; margin: 0; background: #07101b; color: #edf3ff; }
    main { max-width: 1080px; margin: 0 auto; padding: 56px 24px 72px; }
    h1 { margin: 0 0 10px; font-size: 2.8rem; }
    p { line-height: 1.7; color: #c3d3ea; }
    .hero { margin-bottom: 28px; }
    .cta-row, .version-list { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 20px; }
    .button, .tag { display: inline-flex; align-items: center; border-radius: 999px; padding: 10px 16px; text-decoration: none; color: inherit; border: 1px solid rgba(255,255,255,0.14); background: rgba(255,255,255,0.04); }
    .button.primary { background: linear-gradient(135deg, #5b8cff, #63c7ff); color: #07101b; border: none; font-weight: 600; }
    section { margin-top: 36px; padding: 24px; border-radius: 22px; border: 1px solid rgba(255,255,255,0.1); background: rgba(255,255,255,0.03); }
    ul { margin: 12px 0 0; padding-left: 18px; }
    li { margin: 8px 0; }
    a { color: #9ec5ff; }
  </style>
</head>
<body>
  <main>
    <div class="hero">
      <div class="tag">InnoRouter DocC Portal</div>
      <h1>InnoRouter Documentation</h1>
      <p>Detailed guides and API reference for the latest released InnoRouter surface. The repository README stays focused on overview and quick start, while this DocC site holds the module-level reference set.</p>
      <div class="cta-row">
        ${primary_docs_link}
        <a class="button" href="$REPO_URL">GitHub repository</a>
        <a class="button" href="$REPO_URL/blob/main/README.md">README</a>
      </div>
    </div>
    ${latest_section}
    <section>
      <h2>Released versions</h2>
      <ul>
        ${version_links:-<li>No released versions have been published yet.</li>}
      </ul>
    </section>
    <section>
      <h2>Repository guidance</h2>
      <ul>
        <li><a href="$REPO_URL/tree/main/Examples">Examples</a> contains human-facing examples that use the latest idiomatic API shape.</li>
        <li><a href="$REPO_URL/tree/main/ExamplesSmoke">ExamplesSmoke</a> contains CI-facing smoke fixtures that prioritize compiler stability.</li>
        <li><a href="$REPO_URL/blob/main/RELEASING.md">RELEASING.md</a> documents the semver tag flow and GitHub Release + DocC publishing contract.</li>
      </ul>
    </section>
  </main>
</body>
</html>
EOF
}

all_symbol_graph_args=()
echo "[build-docc-site] Extracting public symbol graphs for DocC cross-module links"
for symbol_module in "${SYMBOL_GRAPH_MODULES[@]}"; do
  extract_module_symbols "$symbol_module" "$temp_root/symbol-graphs/$symbol_module"
  all_symbol_graph_args+=(--additional-symbol-graph-dir "$temp_root/symbol-graphs/$symbol_module")
done

for module in "${DOCC_MODULES[@]}"; do
  IFS='|' read -r target catalog slug display_name bundle_id <<<"$module"
  echo "[build-docc-site] Building ${target}"
  extract_module_symbols "$target" "$temp_root/current-module-symbols/$target"
  build_module_archive \
    "$target" \
    "$catalog" \
    "$OUTPUT_DIR/$VERSION/$slug" \
    "$bundle_id" \
    "$display_name" \
    "/${REPO_NAME}/${VERSION}/${slug}" \
    "$temp_root/current-module-symbols/$target"
  render_module_entry_redirect "$OUTPUT_DIR/$VERSION/$slug" "$target"

  if [[ "$SKIP_LATEST" != "true" ]]; then
    build_module_archive \
      "$target" \
      "$catalog" \
      "$OUTPUT_DIR/latest/$slug" \
      "$bundle_id" \
      "$display_name" \
      "/${REPO_NAME}/latest/${slug}" \
      "$temp_root/current-module-symbols/$target"
    render_module_entry_redirect "$OUTPUT_DIR/latest/$slug" "$target"
  fi
done

render_version_portal "$OUTPUT_DIR/$VERSION" "InnoRouter ${VERSION}"
if [[ "$SKIP_LATEST" != "true" ]]; then
  render_version_portal "$OUTPUT_DIR/latest" "InnoRouter latest"
fi
render_root_portal "$OUTPUT_DIR/index.html"
touch "$OUTPUT_DIR/.nojekyll"

warning_output="$(grep -n "warning:" "$build_log" || true)"
if [[ -n "$warning_output" ]]; then
  echo "[build-docc-site] Failed: build emitted warnings" >&4
  printf '%s\n' "$warning_output" >&4
  exit 1
fi

echo "[build-docc-site] Site generated at $OUTPUT_DIR"
