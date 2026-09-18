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


SEMVER = re.compile(r"(?<![0-9.])[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?![0-9.])")
# `published` must be the whole word. A substring test also accepted
# `unpublished`, which reads as the exact opposite of what it asserted.
PUBLISHED = re.compile(r"(?<![A-Za-z])published(?![A-Za-z])", re.IGNORECASE)
UNPUBLISHED = re.compile(r"(?<![A-Za-z])unpublished(?![A-Za-z])", re.IGNORECASE)
IMPLEMENTATION_FIELD = re.compile(
    r"^- Implementation (?:state|status): (.*)$", re.MULTILINE
)
DEPLOYED_FIELD = re.compile(r"^\| 구현 상태 \| (.*?) \|$", re.MULTILINE)


def require_review_status(text: str, label: str, pattern: str) -> None:
    matches = re.findall(pattern, text, re.MULTILINE)
    if not matches:
        fail(f"{label} must declare Draft, Reviewed, or Approved document status")
    if len(matches) > 1:
        fail(f"{label} declares {len(matches)} document statuses; exactly one is allowed")


def require_publication(text: str, label: str) -> None:
    """Require exactly one implementation field that claims a real release.

    A document may legitimately say its implementation is unpublished. What it
    may not do is say that and still satisfy a publication check.
    """
    fields = IMPLEMENTATION_FIELD.findall(text)
    if not fields:
        fail(f"{label} must record the implementation state separately from review status")
    if len(fields) > 1:
        fail(f"{label} declares {len(fields)} implementation states; exactly one is allowed")
    body = fields[0]
    if UNPUBLISHED.search(body):
        fail(f"{label} records an unpublished implementation: {body!r}")
    if not PUBLISHED.search(body):
        fail(f"{label} must record the published implementation separately from review status")
    if not SEMVER.search(body):
        fail(f"{label} must name the version its implementation was published in: {body!r}")


def require_deployment(text: str, label: str) -> None:
    fields = DEPLOYED_FIELD.findall(text)
    if not fields:
        fail(f"{label} must record its deployed implementation status")
    if len(fields) > 1:
        fail(f"{label} declares {len(fields)} implementation states; exactly one is allowed")
    body = fields[0]
    if "미배포" in body or "배포 예정" in body:
        fail(f"{label} records an undeployed implementation as deployed: {body!r}")
    if "배포 완료" not in body:
        fail(f"{label} must record its deployed implementation status")
    if not SEMVER.search(body):
        fail(f"{label} must name the version it was deployed in: {body!r}")


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

    require_publication(strategy, "strategy")
    require_publication(specification, "functional specification")
    require_deployment(capability_spec, "capability specification")

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
