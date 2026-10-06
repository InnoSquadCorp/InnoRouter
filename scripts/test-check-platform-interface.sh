#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/check-platform-interface.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/innorouter-interface-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

write_fixture() {
  local mode_flag="$1"
  local target="${2:-arm64-apple-macos15.0}"
  local products="$FIXTURE_ROOT/Build/Products/Release"
  rm -rf "$FIXTURE_ROOT/Build"

  for module in InnoRouter InnoRouterInspector InnoRouterTesting; do
    local module_dir="$products/$module.swiftmodule"
    mkdir -p "$module_dir"
    {
      printf '// swift-module-flags: -target %s -enable-library-evolution %s -module-name %s\n' \
        "$target" "$mode_flag" "$module"
      case "$module" in
        InnoRouter)
          for import_name in \
            InnoRouterCore InnoRouterDeepLink InnoRouterMacros InnoRouterSwiftUI InnoRouterSystem; do
            printf '@_exported import %s\n' "$import_name"
          done
          ;;
        InnoRouterInspector)
          printf 'public struct RouterInspectorImportLimits {}\n'
          ;;
        InnoRouterTesting)
          printf 'final public class RouterTestStore {}\n'
          ;;
      esac
    } > "$module_dir/arm64-apple-macos.swiftinterface"
  done
}

assert_passes() {
  local mode_flag="$1"
  write_fixture "$mode_flag"
  "$SUBJECT" "$FIXTURE_ROOT" macOS >/dev/null
}

assert_rejects_missing_swift_six() {
  write_fixture '-warnings-as-errors'
  if "$SUBJECT" "$FIXTURE_ROOT" macOS >/dev/null 2>&1; then
    echo '[test-platform-interface] Expected a non-Swift-6 interface to fail' >&2
    exit 1
  fi
}

assert_passes '-swift-version 6'
assert_passes '-language-mode 6'
assert_rejects_missing_swift_six

write_fixture '-language-mode 6' 'arm64-apple-xros2.0-simulator'
scene_dir="$FIXTURE_ROOT/Build/Products/Release/InnoRouterSwiftUI.swiftmodule"
mkdir -p "$scene_dir"
scene_interface="$scene_dir/arm64-apple-xros.swiftinterface"
cat > "$scene_interface" <<'EOF'
@_Concurrency.MainActor public struct RouterImmersiveSpaceScene<R> : SwiftUI.Scene where R : InnoRouterCore.DestinationRoute, R : InnoRouterCore.RouterSceneRoute {
  @_Concurrency.MainActor public init(id: Swift.String, store: InnoRouterSwiftUI.RouterStore<R>, rendering: InnoRouterSwiftUI.RouterHostViewDescriptor<R>? = nil, presentations: InnoRouterSwiftUI.RouterPresentationViewCatalog<R> = .stack)
  @_Concurrency.MainActor public var body: some SwiftUI.Scene { get }
}
EOF
"$SUBJECT" "$FIXTURE_ROOT" visionOS >/dev/null
python3 - "$scene_interface" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(".", "::").replace("= ::stack", "= .stack"))
PY
"$SUBJECT" "$FIXTURE_ROOT" visionOS >/dev/null
printf 'public struct RouterImmersiveActivation {}\n' >> "$scene_interface"
if "$SUBJECT" "$FIXTURE_ROOT" visionOS >/dev/null 2>&1; then
  echo '[test-platform-interface] Expected public transport leakage to fail' >&2
  exit 1
fi

echo '[test-platform-interface] Xcode 26.6 and Xcode 27 Swift 6 flag dialects passed'
