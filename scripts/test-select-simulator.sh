#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/select-simulator.py"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat >"$TEMP_DIR/devices.json" <<'JSON'
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.tvOS-26-9": [
      {"name": "Older", "udid": "TV-26-9", "isAvailable": true, "state": "Shutdown"}
    ],
    "com.apple.CoreSimulator.SimRuntime.tvOS-26-10": [
      {"name": "Shutdown Newest", "udid": "TV-26-10-A", "isAvailable": true, "state": "Shutdown"},
      {"name": "Booted Newest", "udid": "TV-26-10-B", "isAvailable": true, "state": "Booted"}
    ],
    "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
      {"name": "Unavailable", "udid": "TV-27-0", "isAvailable": false, "state": "Shutdown"}
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
      {"name": "Watch", "udid": "WATCH-27-0", "isAvailable": true, "state": "Shutdown"}
    ]
  }
}
JSON

selected="$(
  python3 "$SUBJECT" \
    "$TEMP_DIR/devices.json" \
    com.apple.CoreSimulator.SimRuntime.tvOS
)"
if [[ "$selected" != "TV-26-10-B" ]]; then
  echo "[test-select-simulator] expected newest booted tvOS simulator, got $selected" >&2
  exit 1
fi
echo "[test-select-simulator] newest numeric runtime and booted tie-break: passed"

if python3 "$SUBJECT" \
  "$TEMP_DIR/devices.json" \
  com.apple.CoreSimulator.SimRuntime.xrOS >/dev/null 2>&1; then
  echo "[test-select-simulator] missing runtime unexpectedly succeeded" >&2
  exit 1
fi
echo "[test-select-simulator] missing runtime: failed as expected"

printf '{invalid json' >"$TEMP_DIR/invalid.json"
if python3 "$SUBJECT" \
  "$TEMP_DIR/invalid.json" \
  com.apple.CoreSimulator.SimRuntime.tvOS >/dev/null 2>&1; then
  echo "[test-select-simulator] invalid JSON unexpectedly succeeded" >&2
  exit 1
fi
echo "[test-select-simulator] invalid JSON: failed as expected"

echo '[test-select-simulator] All scenarios passed'
