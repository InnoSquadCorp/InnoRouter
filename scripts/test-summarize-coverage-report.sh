#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

python3 - "$TEMP_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
gated = """SF:/repo/Sources/InnoRouterCore/Reducer.swift
LF:4
LH:3
end_of_record
"""
full = gated + """SF:/repo/Sources/InnoRouterSwiftUI/Host.swift
LF:6
LH:2
end_of_record
SF:/repo/Sources/InnoRouterMacrosPlugin/Plugin.swift
LF:2
LH:1
end_of_record
"""
(root / "gated.lcov").write_text(gated, encoding="utf-8")
(root / "full.lcov").write_text(full, encoding="utf-8")
PY

python3 "$ROOT_DIR/scripts/summarize-coverage-report.py" \
  --gated "$TEMP_DIR/gated.lcov" \
  --comprehensive "$TEMP_DIR/full.lcov" \
  --output "$TEMP_DIR/summary.json"

python3 - "$TEMP_DIR/summary.json" <<'PY'
import json
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["schemaVersion"] == 1
assert report["gated"]["totals"]["lineCoveragePercent"] == 75.0
assert report["comprehensive"]["components"]["Macros"]["hitLines"] == 1
assert report["visibilityDelta"] == {"additionalFiles": 2, "additionalFoundLines": 8}
PY

echo "[test-coverage-summary] Component summary scenarios passed"
