#!/usr/bin/env python3
"""Boot one simulator, retrying a boot that never reaches the booted state.

Hosted runners occasionally leave `simctl bootstatus` waiting on a device that
never finishes booting. One stuck boot used to fail the whole job and force a
manual re-run. Before each retry the device is shut down and erased, which
clears the half-booted state. The last attempt's failure still fails the job.
"""

from __future__ import annotations

import os
import subprocess
import sys


def setting(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def simctl(*arguments: str, timeout: float) -> bool:
    command = ["xcrun", "simctl", *arguments]
    try:
        completed = subprocess.run(command, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        print(f"[boot-simulator] {' '.join(command)} timed out after {timeout:g}s", file=sys.stderr)
        return False
    return completed.returncode == 0


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: boot-simulator.py <udid>", file=sys.stderr)
        return 2

    udid = sys.argv[1]
    attempts = int(setting("SIMULATOR_BOOT_ATTEMPTS", 3))
    boot_timeout = setting("SIMULATOR_BOOT_TIMEOUT", 60)
    status_timeout = setting("SIMULATOR_BOOTSTATUS_TIMEOUT", 180)

    for attempt in range(1, attempts + 1):
        # `boot` fails harmlessly for an already booted device, so only
        # `bootstatus` decides whether this attempt succeeded.
        simctl("boot", udid, timeout=boot_timeout)
        if simctl("bootstatus", udid, "-b", timeout=status_timeout):
            print(f"[boot-simulator] {udid} booted on attempt {attempt} of {attempts}")
            return 0
        if attempt < attempts:
            print(
                f"[boot-simulator] attempt {attempt} did not boot {udid}; "
                "shutting down and erasing before retrying",
                file=sys.stderr,
            )
            simctl("shutdown", udid, timeout=boot_timeout)
            simctl("erase", udid, timeout=boot_timeout)

    print(f"[boot-simulator] {udid} did not boot after {attempts} attempts", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
