#!/usr/bin/env bash
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:?Usage: run_simulator.sh ipad|vision <booted-simulator-uuid>}"
device="${2:?Pass an explicitly selected booted simulator UUID}"
case "$platform" in
  ipad) scheme=RouterNativeIPadProbe; bundle=com.innosquad.router.native-ipad-probe; sdk=iphonesimulator; runtime=iOS; marker=iPadOS ;;
  vision) scheme=RouterNativeVisionProbe; bundle=com.innosquad.router.native-vision-probe; sdk=xrsimulator; runtime=xrOS; marker=visionOS ;;
  *) echo "Expected ipad or vision" >&2; exit 2 ;;
esac

# Never create, boot, erase, or shut down a caller's simulator implicitly.
xcrun simctl list devices --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
matches = [(runtime, item) for runtime, items in devices.items() for item in items if item["udid"] == sys.argv[1]]
if len(matches) != 1:
    raise SystemExit("Simulator UUID must identify exactly one device")
runtime, item = matches[0]
if item["state"] != "Booted" or not item["isAvailable"] or sys.argv[2] not in runtime:
    raise SystemExit("Select an available, booted simulator for this platform")
' "$device" "$runtime"
if xcrun simctl spawn "$device" launchctl list | rg -F "application.$bundle"; then
  echo "The probe is already running; let it finish first." >&2
  exit 1
fi

mkdir -p "$PROBE_ROOT/.build"
PROBE_LOG_DIR="$(mktemp -d "$PROBE_ROOT/.build/native-$platform.XXXXXX")"
PROBE_DERIVED="$PROBE_ROOT/.build/derived-$platform"
echo "Native evidence: $PROBE_LOG_DIR"
xcodebuild -project "$PROBE_ROOT/NativeSceneSmoke.xcodeproj" -scheme "$scheme" \
  -configuration Debug -destination "id=$device" -derivedDataPath "$PROBE_DERIVED" \
  CODE_SIGNING_ALLOWED=NO build > "$PROBE_LOG_DIR/build.log" 2>&1
xcrun simctl install "$device" "$PROBE_DERIVED/Build/Products/Debug-$sdk/$scheme.app"
python3 - "$device" "$bundle" "$PROBE_LOG_DIR/runtime.log" <<'PY'
import subprocess
import sys

with open(sys.argv[3], "w", encoding="utf-8") as output:
    subprocess.run([
        "xcrun", "simctl", "launch", "--console", sys.argv[1], sys.argv[2],
    ], stdout=output, stderr=subprocess.STDOUT, timeout=180, check=True)
PY
rg "^PASS native $marker allow/reject/cancel$" "$PROBE_LOG_DIR/runtime.log"
if rg '^FAIL ' "$PROBE_LOG_DIR/runtime.log"; then exit 1; fi
