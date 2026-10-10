#!/usr/bin/env bash
set -euo pipefail

# Run serially in a disposable checkout. Remove only the concrete lifecycle
# leaf to prove the hosted regression fails for the original missing callback,
# then restore it and require the same assertions to pass. Never edit tests.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source_file=Sources/InnoRouterSwiftUI/RouterSceneHost.swift
scratch="$(mktemp -d)"
cp "$source_file" "$scratch/RouterSceneHost.swift"
restore() {
  cp "$scratch/RouterSceneHost.swift" "$source_file"
  rm -rf "$scratch"
}
trap restore EXIT

python3 - "$source_file" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
leaf = '            Color.clear.frame(width: 0, height: 0)\n'
if text.count(leaf) != 1:
    raise SystemExit('Expected exactly one immersive lifecycle leaf')
path.write_text(text.replace(leaf, '', 1))
PY

filter='MountedImmersiveLifetimeTests/firstAppearanceAfterRepair'
status=0
swift test --jobs 2 --no-parallel --filter "$filter" > "$scratch/before.log" 2>&1 || status=$?
cat "$scratch/before.log"
if [[ "$status" -eq 0 ]] || ! grep -Fq 'Empty host must receive native appearance after repair' "$scratch/before.log"; then
  echo 'Regression did not fail for the original missing native callback' >&2
  exit 1
fi
cp "$scratch/RouterSceneHost.swift" "$source_file"
swift test --jobs 2 --no-parallel --filter "$filter"
echo 'Immersive first-mount regression: original callback missing; corrected host passed'
