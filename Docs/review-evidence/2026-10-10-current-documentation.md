# Current documentation audit — 2026-10-10

## Scope and release baseline

This is a documentation/static-check change, not a new library release.
The starting main revision was `8da363ad4abfb8f7f5117f54acfbaf9ff78f9640`.
The official remote `7.0.0` tag resolves to
`33b0da7639105cfa8e6f5acffa3badb91b5e0254`. The GitHub Release is non-draft,
non-prerelease and was published at `2026-10-08T05:31:05Z`:
[release](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0).
The [versioned DocC site](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
returned HTTP 200 during this audit.

`Package.swift` and all production `Sources/**/*.swift` files are unchanged
from that published tag. Documentation under `Sources/**/*.docc` is updated.
Source checks used the actual outcome cases in `RouterTransition.swift`,
presentation methods in `RouterActions.swift`, the consolidated 7.0 migration
contract, and the compiled-target source examples under `Examples/`. Inspection
of source is not a replacement for running the compiler.

## Changes

- Seven maintained READMEs now cover the same 13 sections and contain six
  identical Swift blocks: installation, quick start, configured store,
  outcome handling, deep links, and typed presentation results.
- Full English and Korean advanced material remains in
  [Navigation-Guide.md](../Navigation-Guide.md) and
  [Navigation-Guide.ko.md](../Navigation-Guide.ko.md), with links repaired.
- All seven historical 5.2.1 READMEs remain linked from the
  [archive index](../Archive/README-translations.md), explicitly separated from
  current API guidance. Their files were verified in the 5.2.1 Git tree.
- Published release identity replaces stale preparation claims in current
  entry points. The release checklist preserves the original dated preparation
  evidence and unresolved qualification boundaries.
- SwiftUI DocC now distinguishes exact restoration from explicit topology
  reconciliation and requires dormant-branch consent at the Store and renderer.
- Current guidance covers throwing setup, read-only drafts, scope expiry,
  cancellation and deferral, explicit feature composition, Codable persistence,
  finite limits, native scene identity, and payload-safe debugging.
- Documentation gates include every current language and both detailed guides.

## Checks executed

Passed:

- `python3 scripts/check-readme-translations.py`: seven languages, 13 sections,
  six identical annotated Swift blocks per language, runtime/platform/product
  literals, source-symbol presence, local file links, and legacy index coverage
- `python3 scripts/test-check-readme-translations.py`: seven tests, including
  rejection of a missing locale, changed snippet, stale version, missing API
  contract, broken relative link, and missing section
- `bash scripts/test-check-doc-metadata.sh`: seven tests
- `python3 scripts/check-doc-metadata.py .`
- `bash scripts/check-changelog-phase.sh CHANGELOG.md`
- `bash scripts/check-release-identity.sh 7.0.0 ga`
- `bash -n scripts/check-docs-consistency.sh scripts/check-docs-code-blocks.sh`
- `git diff --cached --check` (after staging; final EOF whitespace corrected)
- Static fence annotation/balancing scan: nine README/reference files,
  55 Swift blocks
- `git diff --exit-code 7.0.0 -- Package.swift 'Sources/**/*.swift'`: no changes

`bash scripts/check-docs-consistency.sh` was attempted and stopped at its
prerequisite check: **Swift is unavailable**. Its independent static components
above were run directly; this does not turn the full gate into a pass.

## Remaining validation

Swift snippet typechecking, package/runtime tests, macro expansion, public API
compilation, DocC rendering, Apple platform/scene tests, and native human language
review were not run for this change. Use the documented Apple-toolchain gates
before merge. Local file-link checks do not validate every external URL or DocC
symbol resolver. The versioned DocC site's availability is not evidence that
these unmerged edits have been published there.

An independent final diff review covered the root README examples, source API
shapes, script integration, maintained/historical separation and preserved
references. No runtime files, release tags, remote branches, or PRs were changed
by this documentation work. Publication still requires explicit approval.
