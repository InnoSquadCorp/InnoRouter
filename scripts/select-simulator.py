#!/usr/bin/env python3
"""Select an available simulator from the newest matching runtime."""

from __future__ import annotations

import json
from pathlib import Path
import sys
from typing import Any


def runtime_version(identifier: str, prefix: str) -> tuple[int, ...] | None:
    if not identifier.startswith(prefix):
        return None

    suffix = identifier[len(prefix) :]
    if suffix.startswith("-"):
        suffix = suffix[1:]
    if not suffix:
        return ()

    components = suffix.split("-")
    if any(not component.isdecimal() for component in components):
        return None
    return tuple(int(component) for component in components)


def select_simulator(payload: dict[str, Any], prefix: str) -> str:
    devices_by_runtime = payload.get("devices", {})
    if not isinstance(devices_by_runtime, dict):
        raise ValueError("simctl payload must contain a devices object")

    candidates: list[tuple[tuple[int, ...], bool, str, str]] = []
    for runtime, devices in devices_by_runtime.items():
        if not isinstance(runtime, str) or not isinstance(devices, list):
            continue

        version = runtime_version(runtime, prefix)
        if version is None:
            continue

        for device in devices:
            if not isinstance(device, dict):
                continue
            if device.get("isAvailable", True) is False:
                continue

            udid = device.get("udid")
            if not isinstance(udid, str) or not udid:
                continue

            # Runtime version is authoritative. Within that runtime, prefer an
            # already-booted simulator, then use stable name/UDID tie-breakers.
            candidates.append(
                (
                    version,
                    device.get("state") == "Booted",
                    str(device.get("name", "")),
                    udid,
                )
            )

    if not candidates:
        raise LookupError(f"no available simulator matches runtime prefix {prefix!r}")

    return max(candidates)[-1]


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: select-simulator.py <simctl-devices-json> <runtime-prefix>",
            file=sys.stderr,
        )
        return 2

    devices_path = Path(sys.argv[1])
    runtime_prefix = sys.argv[2]
    try:
        payload = json.loads(devices_path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("simctl payload root must be an object")
        print(select_simulator(payload, runtime_prefix))
    except (OSError, json.JSONDecodeError, LookupError, ValueError) as error:
        print(f"[select-simulator] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
