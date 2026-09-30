#!/usr/bin/env bash
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
device="${1:?Usage: open_inspector_simulator.sh <booted-iOS-simulator-uuid>}"
bundle=com.innosquad.router.inspector-probe

# An explicit, already booted simulator is required. Never touch real devices.
xcrun simctl list devices --json | python3 -c '
import json, sys
matches = [(runtime, item) for runtime, items in json.load(sys.stdin)["devices"].items()
           for item in items if item["udid"] == sys.argv[1]]
if len(matches) != 1:
    raise SystemExit("Simulator UUID must identify exactly one device")
runtime, item = matches[0]
if item["state"] != "Booted" or not item["isAvailable"] or "iOS" not in runtime:
    raise SystemExit("Select an available, booted iOS simulator")
' "$device"
if xcrun simctl spawn "$device" launchctl list | rg -F "application.$bundle"; then
  echo "Inspector probe is already running; close that probe before rebuilding." >&2
  exit 1
fi

mkdir -p "$PROBE_ROOT/.build"
PROBE_LOG_DIR="$(mktemp -d "$PROBE_ROOT/.build/inspector-simulator.XXXXXX")"
PROBE_DERIVED="$PROBE_ROOT/.build/derived-inspector"
xcodebuild -project "$PROBE_ROOT/NativeSceneSmoke.xcodeproj" -scheme RouterInspectorProbe \
  -configuration Debug -destination "id=$device" -derivedDataPath "$PROBE_DERIVED" \
  CODE_SIGNING_ALLOWED=NO build > "$PROBE_LOG_DIR/build.log" 2>&1
xcrun simctl install "$device" "$PROBE_DERIVED/Build/Products/Debug-iphonesimulator/RouterInspectorProbe.app"
xcrun simctl launch --stdout="$PROBE_LOG_DIR/runtime.log" --stderr="$PROBE_LOG_DIR/runtime-error.log" \
  "$device" "$bundle"
echo "Inspector launched; this is not a UI pass. Evidence: $PROBE_LOG_DIR"
