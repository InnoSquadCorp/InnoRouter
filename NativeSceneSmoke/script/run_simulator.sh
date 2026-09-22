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
python3 - "$device" "$bundle" "$PROBE_LOG_DIR/runtime.log" "$platform" "$PROBE_DERIVED/Build/Products/Debug-$sdk/$scheme.app" <<'PY'
from pathlib import Path
import subprocess
import sys

runtime_log = Path(sys.argv[3])
if sys.argv[4] == "vision":
    # Independent policy cases must not inherit persisted scene sessions from
    # an earlier run of this disposable probe. No failed case is retried.
    with runtime_log.open("w", encoding="utf-8") as combined:
        for resolution in ("allow", "reject", "cancel"):
            subprocess.run(["xcrun", "simctl", "uninstall", sys.argv[1], sys.argv[2]], check=True)
            subprocess.run(["xcrun", "simctl", "install", sys.argv[1], sys.argv[5]], check=True)
            case_log = runtime_log.with_name(f"runtime-{resolution}.log")
            with case_log.open("w", encoding="utf-8") as output:
                subprocess.run([
                    "xcrun", "simctl", "launch", "--terminate-running-process", "--console",
                    sys.argv[1], sys.argv[2], "--resolution", resolution,
                ], stdout=output, stderr=subprocess.STDOUT, timeout=180, check=True)
            evidence = case_log.read_text(encoding="utf-8")
            combined.write(evidence)
            expected = f"PASS native visionOS {resolution}"
            if expected not in evidence.splitlines() or any(line.startswith("FAIL ") for line in evidence.splitlines()):
                raise SystemExit(f"Native visionOS {resolution} failed; see {case_log}")
        combined.write("PASS native visionOS allow/reject/cancel\n")
else:
    with runtime_log.open("w", encoding="utf-8") as output:
        subprocess.run([
            "xcrun", "simctl", "launch", "--console", sys.argv[1], sys.argv[2],
        ], stdout=output, stderr=subprocess.STDOUT, timeout=180, check=True)
PY
rg "^PASS native $marker allow/reject/cancel$" "$PROBE_LOG_DIR/runtime.log"
if rg '^FAIL ' "$PROBE_LOG_DIR/runtime.log"; then exit 1; fi
