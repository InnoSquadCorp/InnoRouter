#!/usr/bin/env python3
"""Validate resolved example-consumer product and Xcode scheme boundaries."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


EXPECTED_DEPENDENCIES = {
    "InnoRouter": [
        "InnoRouterCore",
        "InnoRouterDeepLink",
        "InnoRouterMacros",
        "InnoRouterSwiftUI",
    ],
    "InnoRouterMacroFirstSmoke": ["InnoRouter"],
    "InnoRouterSpatialConsumerSmoke": ["InnoRouterSpatial"],
    "InnoRouterVisionOSImmersiveExample": ["InnoRouterSpatial"],
}

EXPECTED_TARGET_SOURCES = {
    "InnoRouterMacroFirstSmoke": ["MacrosSmoke.swift"],
    "InnoRouterSpatialConsumerSmoke": ["VisionOSImmersiveSmoke.swift"],
    "InnoRouterVisionOSImmersiveExample": ["VisionOSImmersiveExample.swift"],
}

EXPECTED_EXPORTS = [
    "InnoRouterCore",
    "InnoRouterDeepLink",
    "InnoRouterMacros",
    "InnoRouterSwiftUI",
]


def validate_package(package: dict[str, Any]) -> list[str]:
    """Return resolved-target dependency and source violations."""
    errors: list[str] = []
    raw_targets = package.get("targets")
    if not isinstance(raw_targets, list):
        return ["resolved package has no target list"]

    targets = {
        target.get("name"): target
        for target in raw_targets
        if isinstance(target, dict) and isinstance(target.get("name"), str)
    }

    for target_name, expected_dependencies in EXPECTED_DEPENDENCIES.items():
        target = targets.get(target_name)
        if target is None:
            errors.append(f"Package.swift is missing target {target_name}")
            continue

        actual_dependencies: list[str] = []
        malformed_dependencies: list[Any] = []
        dependencies = target.get("dependencies", [])
        if not isinstance(dependencies, list):
            malformed_dependencies.append(dependencies)
            dependencies = []

        for dependency in dependencies:
            if not isinstance(dependency, dict) or len(dependency) != 1:
                malformed_dependencies.append(dependency)
                continue
            kind, payload = next(iter(dependency.items()))
            if (
                kind != "byName"
                or not isinstance(payload, list)
                or len(payload) != 2
                or not isinstance(payload[0], str)
                or payload[1] is not None
            ):
                malformed_dependencies.append(dependency)
                continue
            actual_dependencies.append(payload[0])

        if (
            malformed_dependencies
            or sorted(actual_dependencies) != expected_dependencies
            or len(actual_dependencies) != len(expected_dependencies)
        ):
            errors.append(
                f"{target_name} must depend on exactly {expected_dependencies}; "
                f"found names={actual_dependencies}, "
                f"unsupported={malformed_dependencies}"
            )

        expected_sources = EXPECTED_TARGET_SOURCES.get(target_name)
        if expected_sources is None:
            continue
        actual_sources = target.get("sources")
        if actual_sources != expected_sources:
            errors.append(
                f"{target_name} must compile exactly {expected_sources}; "
                f"found sources={actual_sources}"
            )

    return errors


def validate_umbrella_source(source: str) -> list[str]:
    """Return umbrella re-export violations after stripping comments."""
    umbrella_code = re.sub(r"/\*.*?\*/", " ", source, flags=re.DOTALL)
    umbrella_code = re.sub(r"//[^\n]*", " ", umbrella_code)
    actual_exports = re.findall(
        r"@_exported\s+import\s+([A-Za-z_][A-Za-z0-9_]*)",
        umbrella_code,
    )
    exported_attribute_count = len(re.findall(r"@_exported\b", umbrella_code))
    public_imports = re.findall(
        r"\bpublic\s+import\s+([A-Za-z_][A-Za-z0-9_]*)",
        umbrella_code,
    )
    if (
        sorted(actual_exports) == EXPECTED_EXPORTS
        and len(actual_exports) == len(EXPECTED_EXPORTS)
        and exported_attribute_count == len(EXPECTED_EXPORTS)
        and not public_imports
    ):
        return []

    return [
        "InnoRouter umbrella must re-export exactly "
        f"{EXPECTED_EXPORTS}; found @_exported={actual_exports}, "
        f"public={public_imports}, attributes={exported_attribute_count}"
    ]


def validate_scheme(
    root: ET.Element,
    scheme_name: str,
    expected_target: str,
) -> list[str]:
    """Return build-action violations for one dedicated consumer scheme."""
    entries = root.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
    references = root.findall(
        "./BuildAction/BuildActionEntries/BuildActionEntry/BuildableReference"
    )
    if len(entries) != 1 or len(references) != 1:
        return [
            f"{scheme_name} must contain exactly one BuildActionEntry and one "
            f"BuildableReference for {expected_target}; "
            f"found entries={len(entries)}, references={len(references)}"
        ]

    reference = references[0]
    expected_attributes = {
        "BuildableIdentifier": "primary",
        "BlueprintIdentifier": expected_target,
        "BuildableName": expected_target,
        "BlueprintName": expected_target,
        "ReferencedContainer": "container:..",
    }
    actual_attributes = {
        attribute: reference.get(attribute)
        for attribute in expected_attributes
    }
    if actual_attributes == expected_attributes:
        return []

    return [
        f"{scheme_name} must build only {expected_target} with attributes "
        f"{expected_attributes}; found {actual_attributes}"
    ]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_dump", type=Path)
    parser.add_argument("umbrella_source", type=Path)
    parser.add_argument("macro_first_scheme", type=Path)
    parser.add_argument("spatial_consumer_scheme", type=Path)
    parser.add_argument("spatial_example_scheme", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        package = json.loads(arguments.package_dump.read_text(encoding="utf-8"))
        umbrella_source = arguments.umbrella_source.read_text(encoding="utf-8")
        macro_scheme = ET.parse(arguments.macro_first_scheme).getroot()
        spatial_scheme = ET.parse(arguments.spatial_consumer_scheme).getroot()
        spatial_example_scheme = ET.parse(arguments.spatial_example_scheme).getroot()
    except (OSError, json.JSONDecodeError, ET.ParseError) as error:
        print(f"failed to read consumer contract inputs: {error}")
        return 1

    errors = []
    errors.extend(validate_package(package))
    errors.extend(validate_umbrella_source(umbrella_source))
    errors.extend(
        validate_scheme(
            macro_scheme,
            arguments.macro_first_scheme.name,
            "InnoRouterMacroFirstSmoke",
        )
    )
    errors.extend(
        validate_scheme(
            spatial_scheme,
            arguments.spatial_consumer_scheme.name,
            "InnoRouterSpatialConsumerSmoke",
        )
    )
    errors.extend(
        validate_scheme(
            spatial_example_scheme,
            arguments.spatial_example_scheme.name,
            "InnoRouterVisionOSImmersiveExample",
        )
    )

    for error in errors:
        print(error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
