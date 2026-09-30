#!/usr/bin/env python3
"""Keep CI resolution and delegated gate boundaries reviewable."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_DIR = ROOT / ".github/workflows"


def require(source: str, fragment: str, context: str) -> None:
    if fragment not in source:
        raise AssertionError(f"{context}: missing {fragment!r}")


def reject(source: str, fragment: str, context: str) -> None:
    if fragment in source:
        raise AssertionError(f"{context}: forbidden {fragment!r}")


resolution_files = (
    "Package.resolved",
    "ConsumerSmoke/Package.resolved",
    "MigrationSmoke/Before/Package.resolved",
    "MigrationSmoke/After/Package.resolved",
    "NativeSceneSmoke/NativeSceneSmoke.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)
for relative_name in resolution_files:
    resolution = ROOT / relative_name
    if not resolution.is_file():
        raise AssertionError(f"resolution contract: missing {relative_name}")
    require(resolution.read_text(encoding="utf-8"), '"revision"', relative_name)

principle_workflow = (WORKFLOW_DIR / "principle-gates.yml").read_text(encoding="utf-8")
for workflow_path in sorted(WORKFLOW_DIR.glob("*.yml")):
    workflow = workflow_path.read_text(encoding="utf-8")
    reject(workflow, "swiftpm-dependency-cache", workflow_path.name)
    reject(workflow, "actions/cache@", workflow_path.name)

require(
    principle_workflow,
    "./scripts/principle-gates.sh --skip-docc-site --skip-source-lint",
    "principle-gates workflow",
)
require(principle_workflow, 'INNOROUTER_DELEGATED_GATES: "true"', "delegation authority")
require(principle_workflow, "./scripts/lint-source-gates.sh", "delegated lint gate")

docs_workflow = (WORKFLOW_DIR / "docs-ci.yml").read_text(encoding="utf-8")
require(docs_workflow, "./scripts/build-docc-site.sh", "delegated DocC gate")

principle_script = (ROOT / "scripts/principle-gates.sh").read_text(encoding="utf-8")
for retained_default in (
    'SKIP_DOCC_SITE=0',
    'SKIP_SOURCE_LINT=0',
    'INNOROUTER_DELEGATED_GATES:-false',
    './scripts/build-docc-site.sh --version preview --skip-latest',
    './scripts/lint-source-gates.sh',
):
    require(principle_script, retained_default, "standalone principle gates")

print("[ci-optimization] Resolution and delegated gate inventory passed")
