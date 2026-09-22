#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <version> <ga|prerelease> [checkout-root]" >&2
  exit 2
fi

VERSION="$1"
CHANNEL="$2"
CHECKOUT_ROOT="${3:-$SCRIPT_DIR/..}"

# Reuse the channel policy: GA notes are cut; prerelease notes stay Unreleased.
bash "$SCRIPT_DIR/check-release-changelog.sh" "$VERSION" "$CHANNEL" "${CHANGELOG_PATH:-$CHECKOUT_ROOT/CHANGELOG.md}"

python3 - "$VERSION" "$CHECKOUT_ROOT" <<'PY'
import re
import sys
from pathlib import Path

version, root = sys.argv[1], Path(sys.argv[2])
runtime_path = root / "Sources/InnoRouterCore/InnoRouterVersion.swift"
try:
    declarations = re.findall(r'^\s*public static let current = "([^"]+)"\s*$', runtime_path.read_text(), re.M)
    if declarations != [version]:
        raise ValueError(f"runtime identity {declarations!r} does not match release {version!r}")
    for name in ("README.md", "README.ko.md"):
        if f'from: "{version}"' not in (root / name).read_text():
            raise ValueError(f"{name} must install release {version}")
except (OSError, ValueError) as error:
    raise SystemExit(f"[check-release-identity] Failed: {error}")
print(f"[check-release-identity] Runtime, installation docs, and release agree on {version}")
PY
