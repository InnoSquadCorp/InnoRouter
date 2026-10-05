#!/usr/bin/env python3
import importlib.util
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import MagicMock, patch

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

    def test_full_simulator_executable_path_allows_sampling(self):
        path = f"/Users/runner/Library/Developer/CoreSimulator/Devices/{DEVICE}/data/A/RouterInspectorProbe.app/RouterInspectorProbe"
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(WATCH.subprocess, "check_output", return_value=path + "\n"), \
             patch.object(WATCH.subprocess, "run") as run:
            run.return_value = WATCH.subprocess.CompletedProcess([], 0, "sample saved", "")
            output = Path(temporary)
            receipt = WATCH.capture_sample(11443, DEVICE, output)
            self.assertEqual(receipt["status"], "captured")
            self.assertEqual(run.call_args.args[0], [
                "/usr/bin/sample", "11443", "3", "1", "-mayDie", "-file",
                str(output / "sample-11443.txt"),
            ])


class InspectorHangObserverTests(unittest.TestCase):
    def run_observer(self, exit_code, stop_signal=None, already_exited=False):
        handlers = {}
        stream = MagicMock()
        stream.__enter__.return_value = stream
        stream.wait.return_value = exit_code
        stream.poll.return_value = exit_code if already_exited else None

        def lines():
            if stop_signal is not None:
                handlers[stop_signal](stop_signal, None)
            yield "not an event\n"

        stream.stdout = lines()
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary, \
             patch("sys.argv", ["watch-inspector-hangs.py", "--device", DEVICE, "--output", temporary]), \
             patch.object(WATCH.subprocess, "Popen", return_value=stream), \
             patch.object(WATCH.signal, "signal", side_effect=lambda sig, handler: handlers.update({sig: handler})), \
             redirect_stderr(stderr):
            self.assertIsNone(WATCH.main())
            receipt = json.loads((Path(temporary) / "observer.json").read_text())
        self.assertEqual(receipt["stream_exit_code"], exit_code)
        self.assertEqual(receipt["stream_stop_requested"],
                         stop_signal is not None and not already_exited)
        return stderr.getvalue(), stream

    def test_unexpected_stream_failure_emits_ci_warning(self):
        stderr, stream = self.run_observer(17)
        self.assertIn("::warning::simctl log stream exited with 17", stderr)
        self.assertIn("Inspector hang diagnostics may be incomplete", stderr)
        stream.terminate.assert_not_called()

    def test_requested_shutdown_does_not_warn(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                stderr, stream = self.run_observer(143, stop_signal=sig)
                self.assertEqual(stderr, "")
                stream.terminate.assert_called_once_with()

    def test_successful_stream_exit_does_not_warn(self):
        stderr, stream = self.run_observer(0)
        self.assertEqual(stderr, "")
        stream.terminate.assert_not_called()

    def test_shutdown_after_stream_failure_does_not_hide_warning(self):
        stderr, _ = self.run_observer(17, stop_signal=signal.SIGTERM, already_exited=True)
        self.assertIn("::warning::simctl log stream exited with 17", stderr)


if __name__ == "__main__":
    unittest.main()
