#!/usr/bin/env python3
"""Preserve a stack sample only when XCTest reports the probe's main loop busy.

This observer does not change UI test timing, retry tests, or determine success.
It samples each affected probe process once and never terminates the app.
"""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import uuid


def is_probe_path(path, device):
    return isinstance(path, str) and (
        f"/CoreSimulator/Devices/{device}/data/".casefold() in path.casefold()
        and path.endswith("/RouterInspectorProbe.app/RouterInspectorProbe")
    )


def capture_sample(pid, device, output):
    receipt = {"pid": pid, "device": device}
    try:
        current_path = subprocess.check_output(
            ["/bin/ps", "-p", str(pid), "-o", "comm="], text=True, timeout=5
        ).strip()
        if not is_probe_path(current_path, device):
            receipt["status"] = "process-exited-or-identity-changed"
        else:
            destination = output / f"sample-{pid}.txt"
            result = subprocess.run(
                ["/usr/bin/sample", str(pid), "3", "1", "-mayDie", "-file", str(destination)],
                capture_output=True, text=True, timeout=20,
            )
            (output / f"sample-{pid}-command.log").write_text(result.stdout + result.stderr)
            receipt.update(status="captured" if result.returncode == 0 else "sample-failed",
                           exit_code=result.returncode, file=destination.name)
    except (OSError, subprocess.SubprocessError) as error:
        receipt.update(status="unavailable", error=str(error))
    (output / f"sample-{pid}-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def process_event(line, device, output, seen):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return
    if not isinstance(event, dict):
        return
    pid = event.get("processID")
    if (type(pid) is not int or pid <= 0 or pid in seen
            or not is_probe_path(event.get("processImagePath"), device)
            or "process main thread busy" not in str(event.get("eventMessage", ""))):
        return
    seen.add(pid)
    with (output / "triggers.ndjson").open("a") as log:
        log.write(json.dumps(event) + "\n")
    capture_sample(pid, device, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    device = str(uuid.UUID(args.device)).upper()
    args.output.mkdir(parents=True, exist_ok=True)
    predicate = 'process == "RouterInspectorProbe" AND eventMessage CONTAINS "process main thread busy"'
    with (args.output / "log-stream-stderr.log").open("w") as stderr:
        with subprocess.Popen(
            ["xcrun", "simctl", "spawn", device, "log", "stream", "--style", "ndjson",
             "--predicate", predicate], stdout=subprocess.PIPE, stderr=stderr, text=True,
        ) as stream:
            def stop(_signum, _frame):
                stream.terminate()
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            seen = set()
            for line in stream.stdout:
                process_event(line, device, args.output, seen)
            return_code = stream.wait()
    (args.output / "observer.json").write_text(json.dumps({
        "device": device, "observed_app_pids": sorted(seen), "stream_exit_code": return_code,
        "note": "No trigger is not proof of a responsive app; UI test results remain authoritative.",
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
