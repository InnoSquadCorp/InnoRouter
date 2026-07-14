# Contributing to InnoRouter

InnoRouter is a SwiftUI-native navigation framework. Contributions are
welcome — bug reports, behaviour proposals, documentation fixes, and
code patches. This guide describes the conventions you can expect
maintainers to apply to your contribution.

## Ways to contribute

- **Report a bug.** Open a GitHub issue with a minimal reproduction.
  Include the host platform, Xcode version, and Swift toolchain. If
  the bug shows up only on a specific Apple platform (visionOS,
  watchOS), call that out explicitly.
- **Propose a behaviour change.** Open a GitHub Discussion under
  *Ideas*, describe the call site you want to enable, and list any
  alternatives you considered. Behaviour changes that touch the
  public surface (`Route`, `NavigationCommand`, `NavigationStore`,
  `ModalStore`, `FlowStore`, the deep-link pipeline) need a
  short rationale that ties the change to one of the principle
  axes in [`Docs/v2-principle-scorecard.md`](Docs/v2-principle-scorecard.md).
- **Fix documentation.** README, DocC catalogs (`Sources/*/*.docc`),
  and the in-repo guides under `Docs/` are all open to PRs. Doc-only
  PRs do not require a CHANGELOG entry.
- **Improve a smoke fixture.** `ExamplesSmoke/*.swift` is the
  compiler-stable surface that CI guards. Adding coverage there is
  one of the highest-leverage contributions. The
  [`Examples/README.md`](Examples/README.md) and
  [`ExamplesSmoke/README.md`](ExamplesSmoke/README.md) files
  document which side to edit for any given change.

## Development setup

```bash
git clone https://github.com/InnoSquadCorp/InnoRouter.git
cd InnoRouter
swift build
swift test
./scripts/principle-gates.sh
```

The principle-gates script is the authoritative local core gate.
Every PR must keep it green. Local platform coverage is not required
for ordinary patches — the GitHub `platforms` workflow compiles every
Apple target and runs tvOS, watchOS, and visionOS Simulator tests on
every PR.

## Branching and PR conventions

- Branch off `main`. Topic-branch names look like
  `feat/<area>`, `fix/<area>`, `docs/<area>`, or `chore/<area>`.
- Keep one logical change per PR. Two unrelated fixes belong in two
  PRs even if they touch nearby files.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
  The first line stays under ~70 characters. The body explains *why*,
  not *what* — diff already shows what.
- A non-trivial PR should add or update tests under `Tests/`. The
  existing property-based and contract tests
  (`*PropertyBasedTests.swift`, `*ContractsTests.swift`,
  `ExecutionContractSpecTests.swift`) are good models for new
  invariants.

## Public API changes

A change is **breaking** if it would fail to compile for an existing
caller, narrow a generic constraint, or change documented runtime
behaviour. Breaking changes target a 4.0 cycle, not a 3.x minor.

If your PR touches the public surface:

1. Update the matching `Baselines/PublicAPI/<Module>.txt` in the same
   commit. The principle-gates baseline diff is intentional.
2. Drop a changelog fragment under `.changes/<slug>.<category>.md`
   instead of editing `CHANGELOG.md` directly — see
   [`.changes/README.md`](.changes/README.md) for the format and
   categories. The release process collates fragments at cut time.
3. Update the relevant DocC article under the affected
   `Sources/*/*.docc` catalog if the change affects how a feature is
   *used*, not just *named*. Create an `Articles/` directory in that
   catalog when the feature needs long-form guidance and one does not
   already exist.

## Macros

Macro changes (`@Routable`, `@CasePathable`) require coverage in both
`Tests/InnoRouterMacrosTests/` (expansion fixtures) and
`Tests/InnoRouterMacrosBehaviorTests/` (runtime round-trip). The
behaviour test target is macOS-only — see the README in that
directory for the toolchain constraint.

## Filing the PR

- Link to the originating issue or Discussion in the PR body.
- Confirm `swift test` and `./scripts/principle-gates.sh` are green
  locally.
- Note any platform you could not exercise locally so reviewers can
  watch the matrix workflow accordingly.

## Code of conduct

By contributing you agree to follow the repository
[Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Security-sensitive findings should not go through public issues —
follow the disclosure process described in [`SECURITY.md`](SECURITY.md).
