#!/usr/bin/env bash
set -euo pipefail

# The real native fault probe queues recovery after repair has committed. The
# old appearance-only waiter must fail before that queued task can run; the
# corrected waiter must pass all three unchanged policy outcomes.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
device="${1:?Pass an explicitly selected booted visionOS simulator UUID}"
source_file=NativeSceneSmoke/Vision/ProbeApp.swift
mkdir -p NativeSceneSmoke/.build
evidence="$(mktemp -d NativeSceneSmoke/.build/native-vision-regression.XXXXXX)"
cp "$source_file" "$evidence/ProbeApp.swift"
restore() { cp "$evidence/ProbeApp.swift" "$source_file"; }
trap restore EXIT

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
condition = '                        && self.store.state.immersiveSpace?.id == "theater"\n'
if text.count(condition) != 1:
    raise SystemExit('Expected exactly one canonical reopening condition')
path.write_text(text.replace(condition, '', 1))
PY
status=0
./NativeSceneSmoke/script/run_simulator.sh vision "$device" injected > "$evidence/original.log" 2>&1 || status=$?
cat "$evidence/original.log"
if [[ "$status" -eq 0 ]] || ! grep -Fq 'FAIL Deferred closure removed canonical space' "$evidence/original.log"; then
  echo 'Original waiter did not fail at the intended canonical-state assertion' >&2
  exit 1
fi
if ! grep -Fq 'NATIVE_FAULT_REPAIR revision=' "$evidence/original.log"; then
  echo 'Original waiter failed before the real native fault fixture was ready' >&2
  exit 1
fi
restore
./NativeSceneSmoke/script/run_simulator.sh vision "$device" injected | tee "$evidence/corrected.log"
echo 'VisionOS reopen regression: original waiter failed; corrected allow/reject/cancel passed'
