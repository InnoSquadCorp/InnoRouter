#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: ./scripts/check-release-changelog.sh <version> <ga|prerelease> [changelog-path]

GA releases require a non-empty `## <version> - YYYY-MM-DD` section below a
fresh `## Unreleased` heading. Pre-releases keep their notes in a non-empty
`## Unreleased` section until the final GA cut.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

VERSION="$1"
CHANNEL="$2"
CHANGELOG_PATH="${3:-$ROOT_DIR/CHANGELOG.md}"

case "$CHANNEL" in
  ga)
    bash "$ROOT_DIR/scripts/resolve-release-metadata.sh" \
      workflow_dispatch "$VERSION" false >/dev/null
    ;;
  prerelease)
    bash "$ROOT_DIR/scripts/resolve-release-metadata.sh" \
      workflow_dispatch "$VERSION" true >/dev/null
    ;;
  *)
    echo "[check-release-changelog] Channel must be ga or prerelease." >&2
    exit 1
    ;;
esac

if [[ ! -f "$CHANGELOG_PATH" ]]; then
  echo "[check-release-changelog] Changelog not found: $CHANGELOG_PATH" >&2
  exit 1
fi

python3 - "$VERSION" "$CHANNEL" "$CHANGELOG_PATH" <<'PY'
from __future__ import annotations

from datetime import date
from pathlib import Path
import re
import sys

version, channel, changelog_path = sys.argv[1:]
lines = Path(changelog_path).read_text(encoding="utf-8").splitlines()


def fail(message: str) -> None:
    print(f"[check-release-changelog] Failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def section_after(index: int) -> list[str]:
    end = len(lines)
    for candidate in range(index + 1, len(lines)):
        if lines[candidate].startswith("## "):
            end = candidate
            break
    return lines[index + 1 : end]


def has_release_note(section: list[str]) -> bool:
    return any(re.match(r"^\s*-\s+\S", line) for line in section)


def has_substantive_content(section: list[str]) -> bool:
    return any(
        line.strip() and not re.match(r"^###\s+\S", line)
        for line in section
    )


unreleased_indices = [
    index for index, line in enumerate(lines) if re.fullmatch(r"## Unreleased\s*", line)
]
if len(unreleased_indices) != 1:
    fail("CHANGELOG.md must contain exactly one `## Unreleased` heading")

unreleased_index = unreleased_indices[0]

if channel == "prerelease":
    if not has_release_note(section_after(unreleased_index)):
        fail("pre-release notes must remain non-empty under `## Unreleased`")

    base_version = version.split("-", maxsplit=1)[0]
    released_base_pattern = re.compile(
        rf"## {re.escape(base_version)} - \d{{4}}-\d{{2}}-\d{{2}}\s*"
    )
    if any(released_base_pattern.fullmatch(line) for line in lines):
        fail(f"cannot publish {version} after its {base_version} GA section exists")

    print(f"[check-release-changelog] {version} pre-release notes are present under Unreleased")
    raise SystemExit(0)

heading_pattern = re.compile(
    rf"## {re.escape(version)} - (\d{{4}}-\d{{2}}-\d{{2}})\s*"
)
release_headings: list[tuple[int, str]] = []
for index, line in enumerate(lines):
    match = heading_pattern.fullmatch(line)
    if match:
        release_headings.append((index, match.group(1)))

if len(release_headings) != 1:
    fail(f"expected exactly one `## {version} - YYYY-MM-DD` heading")

release_index, release_date = release_headings[0]
try:
    date.fromisoformat(release_date)
except ValueError:
    fail(f"release heading contains an invalid date: {release_date}")

if unreleased_index > release_index:
    fail("`## Unreleased` must appear above the release section")

unreleased_section = section_after(unreleased_index)
if has_substantive_content(unreleased_section):
    fail("GA releases must move every changelog entry out of `## Unreleased`")

next_heading_index = next(
    (
        index
        for index in range(unreleased_index + 1, len(lines))
        if lines[index].startswith("## ")
    ),
    None,
)
if next_heading_index != release_index:
    fail(f"the first release below `## Unreleased` must be {version}")

if not has_release_note(section_after(release_index)):
    fail(f"the {version} release section must contain at least one changelog entry")

print(f"[check-release-changelog] {version} GA release cut is valid")
PY
