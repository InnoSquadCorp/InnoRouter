#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/boot-simulator.py"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# A fake `xcrun` records every simctl call. `bootstatus` fails until its
# FAKE_BOOT_SUCCEEDS_ON-th call, or hangs when FAKE_BOOTSTATUS_HANGS is set.
mkdir -p "$TEMP_DIR/bin"
cat >"$TEMP_DIR/bin/xcrun" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_SIMCTL_LOG"
if [[ "${1:-} ${2:-}" == "simctl bootstatus" ]]; then
  if [[ -n "${FAKE_BOOTSTATUS_HANGS:-}" ]]; then
    sleep 30
  fi
  calls="$(grep -c '^simctl bootstatus' "$FAKE_SIMCTL_LOG")"
  [[ "$calls" -ge "${FAKE_BOOT_SUCCEEDS_ON:-1}" ]] && exit 0
  exit 1
fi
exit 0
SH
chmod +x "$TEMP_DIR/bin/xcrun"

run_subject() {
  local log="$1"
  shift
  : >"$log"
  env PATH="$TEMP_DIR/bin:$PATH" FAKE_SIMCTL_LOG="$log" "$@" \
    python3 "$SUBJECT" DEVICE >/dev/null 2>&1
}

count() {
  grep -c "^simctl $1 DEVICE" "$2" || true
}

log="$TEMP_DIR/first.log"
run_subject "$log" FAKE_BOOT_SUCCEEDS_ON=1
if [[ "$(count bootstatus "$log")" != 1 || "$(count erase "$log")" != 0 ]]; then
  echo "[test-boot-simulator] a healthy boot must not retry or erase" >&2
  cat "$log" >&2
  exit 1
fi
echo "[test-boot-simulator] healthy boot needs one attempt: passed"

log="$TEMP_DIR/retry.log"
run_subject "$log" FAKE_BOOT_SUCCEEDS_ON=2
if [[ "$(count bootstatus "$log")" != 2 || "$(count shutdown "$log")" != 1 || "$(count erase "$log")" != 1 ]]; then
  echo "[test-boot-simulator] a stuck first boot must shut down, erase, and boot again" >&2
  cat "$log" >&2
  exit 1
fi
echo "[test-boot-simulator] stuck boot is erased and retried: passed"

log="$TEMP_DIR/exhausted.log"
if run_subject "$log" FAKE_BOOT_SUCCEEDS_ON=99; then
  echo "[test-boot-simulator] a boot that never succeeds must fail the job" >&2
  exit 1
fi
if [[ "$(count bootstatus "$log")" != 3 || "$(count erase "$log")" != 2 ]]; then
  echo "[test-boot-simulator] exhaustion must make exactly three attempts" >&2
  cat "$log" >&2
  exit 1
fi
echo "[test-boot-simulator] exhausted retries fail after three attempts: passed"

log="$TEMP_DIR/hang.log"
if run_subject "$log" FAKE_BOOTSTATUS_HANGS=1 SIMULATOR_BOOT_ATTEMPTS=2 SIMULATOR_BOOTSTATUS_TIMEOUT=1; then
  echo "[test-boot-simulator] a hanging bootstatus must time out and fail" >&2
  exit 1
fi
if [[ "$(count bootstatus "$log")" != 2 ]]; then
  echo "[test-boot-simulator] a timed-out bootstatus must count as a failed attempt" >&2
  cat "$log" >&2
  exit 1
fi
echo "[test-boot-simulator] hanging bootstatus times out per attempt: passed"
