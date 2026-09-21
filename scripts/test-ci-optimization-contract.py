#!/usr/bin/env python3
"""Keep CI cache boundaries and delegated gates reviewable."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CACHE_ACTION = ROOT / ".github/actions/swiftpm-dependency-cache/action.yml"
WORKFLOW_DIR = ROOT / ".github/workflows"


def require(source: str, fragment: str, context: str) -> None:
    if fragment not in source:
        raise AssertionError(f"{context}: missing {fragment!r}")


def reject(source: str, fragment: str, context: str) -> None:
    if fragment in source:
        raise AssertionError(f"{context}: forbidden {fragment!r}")


action = CACHE_ACTION.read_text(encoding="utf-8")
require(
    action,
    "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0",
    "cache action",
)
require(action, "continue-on-error: true", "cache fallback")
require(action, 'status="error-fallback"', "cache fallback reporting")
for key_part in (
    "swiftpm-dependencies-v1-",
    "runner.os",
    "runner.arch",
    "steps.toolchain.outputs.fingerprint",
    "Package.resolved",
    "ConsumerSmoke/Package.resolved",
    "MigrationSmoke/**/Package.resolved",
):
    require(action, key_part, "cache key")

resolution_files = (
    "Package.resolved",
    "ConsumerSmoke/Package.resolved",
    "MigrationSmoke/Before/Package.resolved",
    "MigrationSmoke/After/Package.resolved",
)
for relative_name in resolution_files:
    resolution = ROOT / relative_name
    if not resolution.is_file():
        raise AssertionError(f"resolution contract: missing {relative_name}")
    require(resolution.read_text(encoding="utf-8"), '"revision"', relative_name)

for allowed_path in (
    ".build/repositories",
    ".build/checkouts",
    ".build/prebuilts",
    "repositories/swift-syntax-*",
    "repositories/InnoRouter-*",
    "prebuilts/swift-syntax",
):
    require(action, allowed_path, "cache paths")

for forbidden_path in (
    ".build/arm64-apple-macosx",
    ".build/external-consumer",
    ".build/sanitizers",
    ".build/out",
    ".build/docc-site",
    "restore-keys:",
):
    reject(action, forbidden_path, "cache boundary")

cached_workflows = (
    "principle-gates.yml",
    "docs-ci.yml",
    "coverage.yml",
    "performance-smoke.yml",
    "migration-smoke.yml",
    "sanitizers.yml",
    "release.yml",
)
for workflow_name in cached_workflows:
    workflow = (WORKFLOW_DIR / workflow_name).read_text(encoding="utf-8")
    require(workflow, "uses: ./.github/actions/swiftpm-dependency-cache", workflow_name)
    require(workflow, "vars.INNOROUTER_DISABLE_CI_CACHE != 'true'", workflow_name)

# The platform matrix uses isolated Xcode DerivedData. Restoring the root
# SwiftPM cache in every matrix cell would multiply transfer cost without
# reusing the cached paths.
platforms = (WORKFLOW_DIR / "platforms.yml").read_text(encoding="utf-8")
reject(platforms, "swiftpm-dependency-cache", "platforms.yml")

principle_workflow = (WORKFLOW_DIR / "principle-gates.yml").read_text(encoding="utf-8")
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

print("[ci-optimization] Cache boundary and delegated gate inventory passed")
