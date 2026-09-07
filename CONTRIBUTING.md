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
  public surface (`@Router`, `RouterState`, `RouterAction`, `RouterPlan`,
  `RouterStore`, native hosts, or the link pipeline) need a short rationale
  tied to the 6.0 product contract in
  [`Docs/v6-functional-strategy.md`](Docs/v6-functional-strategy.md).
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
behaviour. Breaking changes after 6.0 target the next major release, not a
6.x minor.

If your PR touches the public surface:

1. Update the affected `InnoRouter`, `InnoRouterTesting`, or
   `InnoRouterInspector` baseline in `Baselines/PublicAPI/` in the same commit.
2. Add the user-visible impact to `CHANGELOG.md` under the current
   `<version> - Unreleased` heading
   in the matching `Breaking`, `Added`, `Changed`, `Fixed`, `Deprecated`,
   `Removed`, or `Security` section. Breaking entries include the required
   call-site migration.
3. Update the relevant DocC article under the affected
   `Sources/*/*.docc` catalog if the change affects how a feature is
   *used*, not just *named*. Create an `Articles/` directory in that
   catalog when the feature needs long-form guidance and one does not
   already exist.

## Changelog entries

Edit `CHANGELOG.md` directly in the same PR when a change affects public API,
package products, supported versions, observable runtime behavior, a
user-visible bug, security, or the contributor/release workflow. Keep entries
under `## Unreleased` until release cut.

Documentation-only and test-only changes, plus internal refactors with no
observable effect, do not require an entry. The CI changelog gate requires a
substantive `Unreleased` change whenever a public API baseline changes; edits
to an older release section do not satisfy it.

## Macros

Macro changes (`@Router`, `@TabItem`, `@DeepLink`, `@Routable`, or
`@CasePathable`) require coverage in both
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
