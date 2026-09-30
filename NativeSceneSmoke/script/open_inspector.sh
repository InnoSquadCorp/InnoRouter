#!/usr/bin/env bash
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROBE_ROOT"
if pgrep -x RouterInspectorProbe >/dev/null; then
  echo "Inspector probe is already running; close it before relaunching." >&2
  exit 1
fi
PROBE_PLATFORM="$(xcrun --sdk macosx --show-sdk-platform-path)"
# This developer-only app uses the Testing adapter outside an XCTest runner.
# Supply the selected Xcode's Testing framework and interoperability runtime.
swift build --jobs 2 --product RouterInspectorProbe \
  -Xlinker -rpath -Xlinker "$PROBE_PLATFORM/Developer/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PROBE_PLATFORM/Developer/usr/lib"
PROBE_BIN="$(swift build --show-bin-path)"
PROBE_APP="$PROBE_ROOT/.build/RouterInspectorProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS"
mkdir -p "$PROBE_APP/Contents/Resources"
cp "$PROBE_BIN/RouterInspectorProbe" "$PROBE_APP/Contents/MacOS/"
cp InspectorInfo.plist "$PROBE_APP/Contents/Info.plist"
for resource in "$PROBE_BIN"/InnoRouter_*.bundle; do
  [[ -d "$resource" ]] || continue
  ditto "$resource" "$PROBE_APP/Contents/Resources/$(basename "$resource")"
done
PROBE_LOG_DIR="$(mktemp -d "$PROBE_ROOT/.build/inspector.XXXXXX")"
echo "Inspector evidence: $PROBE_LOG_DIR"
open -n "$PROBE_APP" --stdout "$PROBE_LOG_DIR/stdout.log" --stderr "$PROBE_LOG_DIR/stderr.log"
echo "Launched for interactive verification; launch success is not a UI PASS."
