#!/usr/bin/env python3
"""Shared release-version classification and ordering policy."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import re
import sys
from typing import Iterable


_IDENTIFIER = r"(?:0|[1-9][0-9]*)"
_VERSION_PATTERN = re.compile(
    rf"^(?P<major>{_IDENTIFIER})\."
    rf"(?P<minor>{_IDENTIFIER})\."
    rf"(?P<patch>{_IDENTIFIER})"
    rf"(?:-(?P<channel>beta|rc)\.(?P<ordinal>{_IDENTIFIER}))?$"
)
_STAGE_RANK = {"beta": 0, "rc": 1, None: 2}


@dataclass(frozen=True)
class ReleaseVersion:
    text: str
    major: int
    minor: int
    patch: int
    channel: str | None
    ordinal: int | None

    @property
    def is_ga(self) -> bool:
        return self.channel is None

    @property
    def ordering_key(self) -> tuple[int, int, int, int, int]:
        return (
            self.major,
            self.minor,
            self.patch,
            _STAGE_RANK[self.channel],
            self.ordinal if self.ordinal is not None else 0,
        )


def parse_version(value: str) -> ReleaseVersion:
    match = _VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError(
            f"unsupported release version {value!r}; expected "
            "N.N.N or N.N.N-(beta|rc).N without leading zeroes"
        )

    channel = match.group("channel")
    ordinal = match.group("ordinal")
    return ReleaseVersion(
        text=value,
        major=int(match.group("major")),
        minor=int(match.group("minor")),
        patch=int(match.group("patch")),
        channel=channel,
        ordinal=int(ordinal) if ordinal is not None else None,
    )


def published_versions(lines: Iterable[str]) -> list[ReleaseVersion]:
    versions: list[ReleaseVersion] = []
    for line in lines:
        label = line.rstrip("\r\n")
        if not label:
            continue
        try:
            versions.append(parse_version(label))
        except ValueError:
            continue
    return versions


def classify(value: str) -> None:
    version = parse_version(value)
    print("ga" if version.is_ga else "prerelease")


def sort_published() -> None:
    versions = sorted(
        published_versions(sys.stdin),
        key=lambda version: version.ordering_key,
        reverse=True,
    )
    for version in versions:
        print(version.text)


def latest_action(candidate_value: str) -> None:
    candidate = parse_version(candidate_value)
    if not candidate.is_ga:
        raise ValueError(
            f"latest candidate {candidate_value!r} must be a GA release"
        )

    existing_ga = [
        version for version in published_versions(sys.stdin) if version.is_ga
    ]
    if not existing_ga:
        print(f"update {candidate.text}")
        return

    highest = max(existing_ga, key=lambda version: version.ordering_key)
    if candidate.ordering_key >= highest.ordering_key:
        print(f"update {candidate.text}")
    else:
        print(f"preserve {highest.text}")


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Apply InnoRouter's supported release-version policy."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify_parser = subparsers.add_parser(
        "classify", help="classify one supported release version"
    )
    classify_parser.add_argument("version")

    subparsers.add_parser(
        "sort-published",
        help="sort supported release labels read from standard input",
    )

    latest_parser = subparsers.add_parser(
        "latest-action",
        help="decide whether a GA candidate may update the latest alias",
    )
    latest_parser.add_argument("candidate")
    return parser


def main() -> int:
    arguments = make_parser().parse_args()
    try:
        if arguments.command == "classify":
            classify(arguments.version)
        elif arguments.command == "sort-published":
            sort_published()
        elif arguments.command == "latest-action":
            latest_action(arguments.candidate)
        else:
            raise AssertionError(f"unhandled command: {arguments.command}")
    except ValueError as error:
        print(f"[release-version-policy] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
