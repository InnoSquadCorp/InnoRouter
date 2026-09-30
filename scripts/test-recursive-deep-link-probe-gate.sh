#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT_DIR/scripts/validate-recursive-deep-link-probe.py"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

python3 - "$TEMP_DIR" <<'PY'
from copy import deepcopy
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
prefix = "[recursive-deep-link-probe] "
valid = {
    "schemaVersion": 1,
    "selfCatalog": ["leaf"],
    "selfLocalResolved": True,
    "selfURLRoundTrips": True,
    "mutualCatalog": ["leaf", "toB.leaf"],
    "growingCatalogComplete": False,
    "growingCatalogEntries": [],
    "growingResolved": False,
    "growingDecision": "traversal-limit-exceeded",
}
fixtures = {"valid": valid}
wrong_catalog = deepcopy(valid)
wrong_catalog["selfCatalog"].append("child.leaf")
fixtures["wrong-catalog"] = wrong_catalog
nil_local_resolve = deepcopy(valid)
nil_local_resolve["selfLocalResolved"] = False
fixtures["nil-local-resolve"] = nil_local_resolve
for name, fixture in fixtures.items():
    (output / f"{name}.txt").write_text(prefix + json.dumps(fixture), encoding="utf-8")
(output / "completion-only.txt").write_text(
    "[recursive-deep-link-probe] semantic assertions passed\n",
    encoding="utf-8",
)
PY

python3 "$SUBJECT" "$TEMP_DIR/valid.txt"

expect_failure() {
  local fixture="$1"
  if python3 "$SUBJECT" "$TEMP_DIR/$fixture.txt" >/dev/null 2>&1; then
    echo "[test-recursive-deep-link-gate] $fixture unexpectedly passed" >&2
    exit 1
  fi
}

expect_failure wrong-catalog
expect_failure nil-local-resolve
expect_failure completion-only
echo "[test-recursive-deep-link-gate] Validator mutation scenarios passed"
