#!/usr/bin/env python3
"""Regression tests for example consumer contract validation."""

from __future__ import annotations

import importlib.util
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from types import ModuleType


sys.dont_write_bytecode = True


def load_validator() -> ModuleType:
    validator_path = Path(__file__).with_name(
        "validate-example-consumer-contracts.py"
    )
    specification = importlib.util.spec_from_file_location(
        "validate_example_consumer_contracts",
        validator_path,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"Could not load validator at {validator_path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


VALIDATOR = load_validator()


def valid_package() -> dict:
    return {
        "targets": [
            {
                "name": "InnoRouter",
                "dependencies": [
                    {"byName": ["InnoRouterCore", None]},
                    {"byName": ["InnoRouterSwiftUI", None]},
                    {"byName": ["InnoRouterDeepLink", None]},
                    {"byName": ["InnoRouterMacros", None]},
                ],
            },
            {
                "name": "InnoRouterMacroFirstSmoke",
                "dependencies": [{"byName": ["InnoRouter", None]}],
                "sources": ["MacrosSmoke.swift"],
            },
            {
                "name": "InnoRouterSpatialConsumerSmoke",
                "dependencies": [{"byName": ["InnoRouterSpatial", None]}],
                "sources": ["VisionOSImmersiveSmoke.swift"],
            },
            {
                "name": "InnoRouterVisionOSImmersiveExample",
                "dependencies": [{"byName": ["InnoRouterSpatial", None]}],
                "sources": ["VisionOSImmersiveExample.swift"],
            },
        ]
    }


def scheme(targets: list[str]) -> ET.Element:
    references = "".join(
        f"""
        <BuildActionEntry>
          <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{target}"
            BuildableName="{target}"
            BlueprintName="{target}"
            ReferencedContainer="container:.." />
        </BuildActionEntry>
        """
        for target in targets
    )
    return ET.fromstring(
        f"""
        <Scheme>
          <BuildAction>
            <BuildActionEntries>{references}</BuildActionEntries>
          </BuildAction>
        </Scheme>
        """
    )


class ConsumerContractValidationTests(unittest.TestCase):
    def test_valid_resolved_targets_pass(self) -> None:
        self.assertEqual(VALIDATOR.validate_package(valid_package()), [])

    def test_macro_consumer_must_compile_only_macro_smoke(self) -> None:
        package = valid_package()
        package["targets"][1]["sources"] = []

        errors = VALIDATOR.validate_package(package)

        self.assertTrue(
            any("must compile exactly ['MacrosSmoke.swift']" in error for error in errors)
        )

    def test_spatial_consumer_rejects_extra_source(self) -> None:
        package = valid_package()
        package["targets"][2]["sources"].append("UnrelatedSmoke.swift")

        errors = VALIDATOR.validate_package(package)

        self.assertTrue(
            any(
                "must compile exactly ['VisionOSImmersiveSmoke.swift']" in error
                for error in errors
            )
        )

    def test_scheme_rejects_the_previous_wrong_spatial_target(self) -> None:
        errors = VALIDATOR.validate_scheme(
            scheme(["InnoRouterExamplesSmoke"]),
            "InnoRouterSpatialConsumerSmoke.xcscheme",
            "InnoRouterSpatialConsumerSmoke",
        )

        self.assertEqual(len(errors), 1)
        self.assertIn("must build only InnoRouterSpatialConsumerSmoke", errors[0])

    def test_scheme_rejects_an_extra_buildable(self) -> None:
        errors = VALIDATOR.validate_scheme(
            scheme(
                [
                    "InnoRouterVisionOSImmersiveExample",
                    "InnoRouterSpatialConsumerSmoke",
                ]
            ),
            "InnoRouterSpatialConsumerSmoke.xcscheme",
            "InnoRouterSpatialConsumerSmoke",
        )

        self.assertEqual(len(errors), 1)
        self.assertIn("exactly one BuildActionEntry", errors[0])

    def test_scheme_accepts_one_exact_consumer_buildable(self) -> None:
        errors = VALIDATOR.validate_scheme(
            scheme(["InnoRouterMacroFirstSmoke"]),
            "InnoRouterMacroFirstSmoke.xcscheme",
            "InnoRouterMacroFirstSmoke",
        )

        self.assertEqual(errors, [])

    def test_scheme_accepts_one_exact_spatial_example_buildable(self) -> None:
        errors = VALIDATOR.validate_scheme(
            scheme(["InnoRouterVisionOSImmersiveExample"]),
            "InnoRouterVisionOSImmersiveExample.xcscheme",
            "InnoRouterVisionOSImmersiveExample",
        )

        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
