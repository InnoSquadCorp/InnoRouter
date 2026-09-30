#!/usr/bin/env python3
from __future__ import annotations

from datetime import date
import pathlib
import re
import sys

NUMBER = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = rf"(?:{NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = re.compile(rf"{NUMBER}\.{NUMBER}\.{NUMBER}(?:-{IDENTIFIER}(?:\.{IDENTIFIER})*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


def fail(message: str) -> None:
    raise SystemExit(f"[doc-metadata] {message}")


def read(root: pathlib.Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        fail(f"missing {relative}")
    return path.read_text()


def field(text: str, key: str, label: str, *, table: bool = False, required: bool = True) -> str | None:
    pattern = rf"^\| {key} \| (.*?) \|$" if table else rf"^- {key}: (.*)$"
    values = re.findall(pattern, text, re.MULTILINE)
    if len(values) > 1:
        fail(f"{label} declares duplicate {key} fields")
    if not values:
        if required:
            fail(f"{label} must declare {key}")
        return None
    return values[0]


def validate_lifecycle(text: str, label: str, *, table: bool = False) -> None:
    keys = (
        ("문서 상태", "구현 상태", "배포 상태", "배포 버전", "배포 커밋", "배포일")
        if table else
        ("Document status", "Implementation (?:state|status)", "Publication status",
         "Published version", "Published commit", "Published date")
    )
    review, implementation, publication = [field(text, key, label, table=table) for key in keys[:3]]
    assert review is not None
    if review.split(";", 1)[0] not in {"Draft", "Reviewed", "Approved"}:
        fail(f"{label} has an invalid document status: {review!r}")
    implementation_states = {"구현 완료", "부분 구현", "미구현"} if table else {"Implemented", "Partial", "Not started"}
    if implementation not in implementation_states:
        fail(f"{label} has an invalid implementation state: {implementation!r}")
    published, unpublished = ("배포 완료", "미배포") if table else ("Published", "Unpublished")
    if publication not in {published, unpublished}:
        fail(f"{label} has an invalid publication status: {publication!r}")
    # These are declared facts, never inferred from prose containing a keyword.
    metadata = [field(text, key, label, table=table, required=False) for key in keys[3:]]
    if publication == unpublished:
        if any(value is not None for value in metadata):
            fail(f"{label} is unpublished but declares published version/commit/date")
        return
    if implementation != ("구현 완료" if table else "Implemented"):
        fail(f"{label} claims publication before implementation is complete")
    version, commit, published_date = metadata
    if version is None or not SEMVER.fullmatch(version):
        fail(f"{label} must name a valid published SemVer")
    if commit is None or not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"{label} must name the full published commit SHA")
    if published_date is None or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", published_date):
        fail(f"{label} must name a published date as YYYY-MM-DD")
    try:
        date.fromisoformat(published_date)
    except ValueError:
        fail(f"{label} has an invalid published date")


def main() -> None:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    for relative, label, table in (
        ("Docs/v6-functional-strategy.md", "strategy", False),
        ("Docs/functional-expansion-spec.md", "functional specification", False),
        ("Docs/6.0.0-next-capabilities-spec.ko.md", "capability specification", True),
    ):
        validate_lifecycle(read(root, relative), label, table=table)
    budgets: dict[str, int] = {}
    for line in read(root, "Baselines/PublicAPI/symbol-budgets.tsv").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[1].isdigit() or fields[0] in budgets:
            fail(f"invalid or duplicate public API budget row: {line}")
        budgets[fields[0]] = int(fields[1])
    rows = re.findall(r"^\| `([^`]+)` \| ([0-9][0-9,]*) \|$",
                      read(root, "Docs/v6-public-api-boundary.md"), re.MULTILINE)
    documented = {name: int(value.replace(",", "")) for name, value in rows}
    if len(documented) != len(rows) or documented != budgets:
        fail(f"public API budget documentation drift: documented={documented}, budgets={budgets}")
    print("[doc-metadata] declared lifecycle fields and API budgets are consistent")


if __name__ == "__main__":
    main()
