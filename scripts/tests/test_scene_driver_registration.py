"""Source-order contract: SwiftUI lifecycle callbacks may run after .task.

This deliberately checks the actual task entry, not a simulated scheduler.
Runtime registry/activation controls live in RouterSceneLifecycleTests.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "Sources/InnoRouterSwiftUI/RouterSceneDriver.swift"


def task_prefix(source):
    task = source.split(".task(id: RouterSceneReconciliationID(", 1)[1]
    body = task.split(")) {", 1)[1]
    return body.split("let reconciliationID", 1)[0]


class SceneDriverRegistrationTests(unittest.TestCase):
    def assert_prepared(self, source):
        prefix = re.sub(r"//[^\n]*", "", task_prefix(source)).strip()
        self.assertEqual(prefix, "registerImmersiveActions()",
                         "Every reconciliation task must register before capturing state or suspending")

    def test_task_registers_without_waiting_for_appearance_or_store_change(self):
        self.assert_prepared(DRIVER.read_text())

    def test_removing_task_registration_is_detected(self):
        source = DRIVER.read_text()
        prefix = task_prefix(source)
        mutated = source.replace(prefix, "\n                ", 1)
        with self.assertRaises(AssertionError):
            self.assert_prepared(mutated)

    def test_registration_after_a_suspension_is_rejected(self):
        source = DRIVER.read_text()
        prefix = task_prefix(source)
        mutated = source.replace(prefix, "\n                await Task.yield()\n                registerImmersiveActions()\n                ", 1)
        with self.assertRaises(AssertionError):
            self.assert_prepared(mutated)


if __name__ == "__main__":
    unittest.main()
