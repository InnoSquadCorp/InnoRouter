#!/usr/bin/env bash
set -euo pipefail
PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROBE_ROOT"
if pgrep -x RouterNativeSceneProbe >/dev/null; then
  echo "A native probe is already running; let it finish before starting another." >&2
  exit 1
fi
swift build --jobs 2
PROBE_BIN="$(swift build --show-bin-path)"
PROBE_APP="$PROBE_ROOT/.build/RouterNativeSceneProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS"
mkdir -p "$PROBE_APP/Contents/Resources"
cp "$PROBE_BIN/RouterNativeSceneProbe" "$PROBE_APP/Contents/MacOS/"
cp Info.plist "$PROBE_APP/Contents/Info.plist"
for resource in "$PROBE_BIN"/InnoRouter_*.bundle; do
  [[ -d "$resource" ]] || continue
  ditto "$resource" "$PROBE_APP/Contents/Resources/$(basename "$resource")"
done
PROBE_LOG_DIR="$(mktemp -d "$PROBE_ROOT/.build/native-scene.XXXXXX")"
echo "Native evidence: $PROBE_LOG_DIR"
python3 - "$PROBE_APP" "$PROBE_LOG_DIR" <<'PY'
import subprocess
import sys

subprocess.run([
    "/usr/bin/open", "-n", "-W", sys.argv[1],
    "--stdout", sys.argv[2] + "/stdout.log",
    "--stderr", sys.argv[2] + "/stderr.log",
], check=True, timeout=120)
PY
rg '^PASS native macOS allow/reject/cancel$' "$PROBE_LOG_DIR/stdout.log"
if rg '^FAIL ' "$PROBE_LOG_DIR/stdout.log"; then exit 1; fi
