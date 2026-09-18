#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"[doc-metadata] {message}")


def read(root: pathlib.Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        fail(f"missing {relative}")
    return path.read_text()


def require_review_status(text: str, label: str, pattern: str) -> None:
    match = re.search(pattern, text, re.MULTILINE)
    if match is None:
        fail(f"{label} must declare Draft, Reviewed, or Approved document status")


def main() -> None:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    strategy = read(root, "Docs/v6-functional-strategy.md")
    specification = read(root, "Docs/functional-expansion-spec.md")
    capability_spec = read(root, "Docs/6.0.0-next-capabilities-spec.ko.md")
    boundary = read(root, "Docs/v6-public-api-boundary.md")
    budget_text = read(root, "Baselines/PublicAPI/symbol-budgets.tsv")

    require_review_status(
        strategy,
        "strategy",
        r"^- Document status: (Draft|Reviewed|Approved)(?:;.*)?$",
    )
    require_review_status(
        specification,
        "functional specification",
        r"^- Document status: (Draft|Reviewed|Approved)(?:;.*)?$",
    )
    require_review_status(
        capability_spec,
        "capability specification",
        r"^\| 문서 상태 \| (Draft|Reviewed|Approved)(?:;.*?)? \|$",
    )

    for text, label in (
        (strategy, "strategy"),
        (specification, "functional specification"),
    ):
        if not re.search(r"^- Implementation (?:state|status): .*published", text, re.MULTILINE):
            fail(f"{label} must record the published implementation separately from review status")
    if not re.search(r"^\| 구현 상태 \| .*배포 완료.* \|$", capability_spec, re.MULTILINE):
        fail("capability specification must record its deployed implementation status")

    budgets: dict[str, int] = {}
    for line in budget_text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[1].isdigit():
            fail(f"invalid public API budget row: {line}")
        budgets[fields[0]] = int(fields[1])

    documented = {
        name: int(value.replace(",", ""))
        for name, value in re.findall(
            r"^\| `([^`]+)` \| ([0-9][0-9,]*) \|$",
            boundary,
            re.MULTILINE,
        )
    }
    if documented != budgets:
        fail(f"public API budget documentation drift: documented={documented}, budgets={budgets}")

    print("[doc-metadata] review, implementation, publication, and API budget metadata match")


if __name__ == "__main__":
    main()
