#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("watch_inspector_hangs", Path(__file__).resolve().parents[1] / "watch-inspector-hangs.py")
WATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WATCH)
DEVICE = "1E926EE8-2A0B-4C47-B835-0C52B77DE728"


class InspectorHangCaptureTests(unittest.TestCase):
    def test_real_xctest_shape_samples_once_per_process(self):
        event = {"processID": 11443, "eventMessage": "XCTAS Error: process main thread busy for 30.0s",
                 "processImagePath": f"/Users/runner/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/Containers/Bundle/Application/A/RouterInspectorProbe.app/RouterInspectorProbe"}
        with tempfile.TemporaryDirectory() as temporary, patch.object(WATCH, "capture_sample") as capture:
            output, seen = Path(temporary), set()
            WATCH.process_event(json.dumps(event), DEVICE, output, seen)
            WATCH.process_event(json.dumps(event), DEVICE, output, seen)
            capture.assert_called_once_with(11443, DEVICE, output)
            self.assertEqual(len((output / "triggers.ndjson").read_text().splitlines()), 1)

    def test_other_device_process_and_non_hang_messages_do_not_sample(self):
        base = {"processID": 11443, "eventMessage": "process main thread busy",
                "processImagePath": f"/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/A/RouterInspectorProbe.app/RouterInspectorProbe"}
        events = ["not json", "[]"]
        for changed in ({"processID": "11443"}, {"processID": True}, {"processID": -1},
                        {"eventMessage": "main run loop idle"}, {"processImagePath": "/another/app"},
                        {"processImagePath": base["processImagePath"].replace(DEVICE, "ANOTHER")}):
            events.append(json.dumps(base | changed))
        with tempfile.TemporaryDirectory() as temporary, patch.object(WATCH, "capture_sample") as capture:
            for event in events:
                WATCH.process_event(event, DEVICE, Path(temporary), set())
            capture.assert_not_called()

    def test_reused_pid_is_rechecked_before_sampling(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(WATCH.subprocess, "check_output", return_value="/another/app\n"), \
             patch.object(WATCH.subprocess, "run") as run:
            receipt = WATCH.capture_sample(11443, DEVICE, Path(temporary))
            self.assertEqual(receipt["status"], "process-exited-or-identity-changed")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
