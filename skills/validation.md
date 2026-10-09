# InnoRouter released skill validation — 2026-10-09

The supported line is stable **7.0.x** (`>=7.0.0 <7.1.0`). The fixture now pins
published **7.0.0** at `33b0da7639105cfa8e6f5acffa3badb91b5e0254`.
The remote lightweight tag and GitHub Release were checked independently.
`Sources/` and `Package.swift` are identical between the historical candidate
`851c63f` and this release; no runtime or production test files changed here.

Fresh isolated remote consumer validation passed **11 Swift tests** with complete
strict concurrency and warnings as errors. The helper checked the official tag
before and after tests, exact SwiftPM pins/graph/workspace, both clean checkout
SHAs, SwiftSyntax prebuilt identity and unchanged consumer source/pins.
[Current machine-readable evidence](validation/consumer-evidence.json).

The fixture contains stack/tab view compile coverage and public runtime tests.
It does not establish device/scene lifecycle, alternate toolchains, every patch,
full library release readiness or AI-host behavior. Those remain separate gates.
A support/lock copy with a fake release SHA was rejected by the official tag
check before any Swift command; a missing-version lock was rejected by the
fixture/support consistency check.

## Historical candidate validation — 2026-10-07

The skill supports the planned stable **7.0.x** line. The tested library is the
unreleased remote main commit `851c63f095e49b700c3a0aa8152a3521a39977e7`, intended
for 7.0.0. The remote 7.0.0 tag lookup returned 404 at this check; a changelog date
or runtime version string is not publication evidence. The skill source is a
separate commit. The original machine-readable evidence is preserved in Git history.

The isolated consumer passed **11 tests** using Xcode 27 / Swift 6.4 on macOS 27
arm64, Swift language mode 6, complete strict concurrency and warnings as errors.
It imports public products only and pins the remote candidate plus SwiftSyntax
604.0.0 (`050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf`). The helper verifies the exact
lock, active graph/workspace, clean checkout SHAs and SwiftSyntax prebuilt identity.
No local-path library override was used.

Coverage includes macro/allowlisted URL resolution; exhaustive push/pop events,
state and revision; draft isolation/resource rejection; throwing configuration;
SwiftUI stack/tab setup; explicit host replacement; expired scope and surviving
sibling controls; snapshot round-trip; typed cancel-button value; caller cancellation;
and transient omission preserving live state while excluding restored UI.

The first fixture build found three authoring errors: `.pop` needed `count:`, an
internal `validateHostRenderer` call was not public, and a tab shape needed its
`extras:` argument. They were corrected to public API calls before the complete
11-test passing rerun. This was fixture correction; library runtime code was unchanged.
A disposable wrong-SHA support record was rejected before any build command.

Skill frontmatter, JSON/Python syntax, relative links and immutable upstream source
targets were checked. `scripts/check-docs-consistency.sh` passed, including its
seven metadata tests and public product/documentation contract check.

These results do not establish native device/window/immersive lifecycle, complete
feature/split/Inspector behavior, full migration execution, alternate toolchains,
all future patches or release readiness. The actual 7.0.0 tag must receive fresh
source and exact-tag consumer checks when published. Installed plugin routing and
AI generation evidence is owned by the central packaging repository. Library
remote CI and release gates remain separate.
