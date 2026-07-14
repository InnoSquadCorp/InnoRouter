# Releasing InnoRouter

This repository ships a Swift Package, versioned DocC documentation, and GitHub Releases from the same semver tag event.

## Release tag contract

Allowed tag format:

- `5.0.0`

Disallowed tag format:

- any tag with a leading `v`
- `release-5.0.0`

The release preflight accepts only numeric identifiers without leading zeroes,
resolves `refs/tags/<version>` exactly, and requires the tagged commit to be
reachable from `origin/main`. All build jobs then checkout that immutable
commit SHA rather than a caller-provided ref name.

### Pre-release tags

Release-candidate and beta channels use the
`<major>.<minor>.<patch>-<channel>.<n>` form:

- `5.0.0-rc.1` (release candidate)
- `5.1.0-beta.2` (beta)

Pre-release tags do **not** match the GA regex above. Publish them
from the same `release.yml` workflow by first creating and pushing
the tag, then manually dispatching the workflow with
`tag=<pre-release-tag>` and `prerelease=true`:

```bash
git tag 5.0.0-rc.1
git push origin 5.0.0-rc.1
```

A pre-release tag push starts the lightweight preflight because the tag glob is
broad, but completes as a successful publication no-op after the exact tag and
event SHA are verified. The manual
pre-release path publishes a GitHub Release marked as pre-release and
a DocC subtree under `/InnoRouter/<tag>/`, but does **not** update
`/latest/`. Only a bare-semver GA tag advances `/latest/`.

GA, release-candidate, and beta DocC builds link source locations to their
exact tag. Preview builds link to the CI commit SHA (or the local `HEAD` SHA),
while other non-release labels fall back to `main`.

## SemVer commitment

InnoRouter 5.x follows [Semantic Versioning](https://semver.org/)
strictly. The public commitment lives in
[`README.md`](README.md#oss-release-and-semver-contract); this section documents
the maintainer-side rules.

### What counts as a breaking change

Within the 5.x line, treating any of the following as in-scope for
a *minor* release is a release-process bug:

- Removing or renaming a public symbol.
- Changing a public method signature so that an existing call site
  fails to compile (adding a non-defaulted parameter, tightening a
  generic constraint, changing the return type).
- Changing the documented runtime behavior of a public API in a way
  that flips the observable outcome for an existing correct caller.
- Raising the minimum supported Swift toolchain or platform floor.

Anything in that list goes to a `6.0.0` cycle. The
`Baselines/PublicAPI` symbol-graph baseline gate is the
machine-checked half of this contract; reviewer judgment is the
other half (behavior changes that don't show up in the symbol
graph still count).

### What is safe in a minor release

- Adding new cases to a non-`@frozen` public enum.
- Adding new defaulted parameters to a public method.
- Adding new public types, methods, or properties.
- Tightening internal/private types.
- Behavior changes that fix a bug whose previous behavior was
  documented as incorrect (call this out in CHANGELOG `[Fixed]`).
- Doc-only changes.

### Toolchain pin

`xcode-version` in `.github/workflows/principle-gates.yml`,
`.github/workflows/platforms.yml`, `.github/workflows/release.yml`,
`.github/workflows/docs-ci.yml`, `.github/workflows/coverage.yml`, and
`.github/workflows/performance-smoke.yml` is pinned to a specific
Xcode release rather than a floating Xcode channel so CI, release tags, DocC
publishing, and performance smoke validation all exercise the same
toolchain family. **When cutting a new release, audit and optionally
bump that pin everywhere** — see the release checklist below.

`swift-tools-version: 6.3` is the package floor. The macro target pins
`swift-syntax` with `.upToNextMinor(from: "603.0.1")`, and every release
workflow selects Xcode 26.3 whose host compiler reports Swift 6.3. These
three levers are intentionally aligned for 5.0. Raising the Swift floor
again belongs in a major release note.

#### Toolchain pin matrix

| Lever | Current value | Source of truth | Notes |
| --- | --- | --- | --- |
| Minimum Xcode for releasing | **26.3** | `xcode-version` in every workflow under `.github/workflows/` | Bumping requires updating every workflow file in the same commit. |
| Bundled Swift host compiler | Swift 6.3 (with Xcode 26.3) | `swift --version` on the pinned Xcode | Must match the package's supported Swift line. |
| Package supported Swift floor | **Swift 6.3** | `swift-tools-version` line in `Package.swift` | Raising belongs in a major release. |
| `swift-syntax` constraint | `.upToNextMinor(from: "603.0.1")` (i.e. `603.0.x`) | `Package.swift` macro plugin dependency | Allows patch bumps; minor / major bumps require a deliberate audit. |
| Apple platform floor | iOS 18 / iPadOS 18 / macOS 15 / tvOS 18 / watchOS 11 / visionOS 2 | `platforms` block in `Package.swift` | Raising belongs in a major release. |
| Macro host availability | macOS only (SwiftSyntax host plugin) | `Tests/InnoRouterMacrosTests`, `Tests/InnoRouterMacrosBehaviorTests` | Linux CI builds the plugin but cannot expand macros. |

To bump the Xcode pin, change `xcode-version` in every workflow file
in a single commit, regenerate the public-API baseline with the same
toolchain (`Baselines/PublicAPI` is symbol-graph–sensitive), and rerun
`./scripts/principle-gates.sh` locally before tagging.

## Changelog cut

Every user-visible change lands directly in `CHANGELOG.md` under
`## Unreleased`. Before creating a release tag:

1. Move the current `Unreleased` categories and entries under a new
   `## <version> - <YYYY-MM-DD>` heading.
2. Recreate `## Unreleased` above it for the next development cycle.
3. Review breaking entries for an explicit migration and commit the cut before
   tagging. Historical release sections are immutable after publication except
   for factual corrections.

The release preflight reads `CHANGELOG.md` from the tag commit itself. A GA tag
is accepted only when `Unreleased` contains no remaining release entries and
the version being published is the first release section below it. A
pre-release keeps its non-empty notes under `Unreleased`; its final GA section
must not already exist.

## What a release publishes

A release tag triggers:

1. code and documentation gates
2. versioned DocC build
3. `/latest/` DocC refresh
4. GitHub Pages deployment
5. GitHub Release creation

The library release and the documentation release are the same event.

## Pages structure

Published documentation lives at:

- `https://innosquadcorp.github.io/InnoRouter/`
- `https://innosquadcorp.github.io/InnoRouter/latest/`
- `https://innosquadcorp.github.io/InnoRouter/<version>/`

Each release version keeps its own documentation subtree. `latest` is updated to the newest released version.

## Required local checks

Run these before tagging:

```bash
swift test
./scripts/principle-gates.sh
./scripts/principle-gates.sh --platforms=all
./scripts/build-docc-site.sh --version preview --skip-latest
```

If you regenerate `Baselines/PublicAPI`, do it with the same pinned
toolchain used in CI. The symbol-graph baseline gate is intentionally
toolchain-sensitive. The local `--platforms=all` probe is compile-only;
it does not execute platform tests. Confirm the GitHub `platforms`
workflow is green for the release commit. The release workflow invokes
that same reusable gate again before it publishes anything.

## CI and CD responsibilities

### CI

`principle-gates.yml`

- runs on pull requests and pushes to `main` and `develop`
- validates runtime tests, smoke builds, fail-fast behavior, and documentation gates

`docs-ci.yml`

- runs on pull requests and pushes to `main` and `develop`
- builds a preview DocC site with `--version preview`
- uploads the generated static site as an artifact

`platforms.yml`

- compiles both `InnoRouterSwiftUI` and the opt-in `InnoRouterSpatial`
  product across all supported Apple platforms
- compiles the visionOS example and smoke consumers that import
  `InnoRouterSpatial` explicitly
- executes tvOS, watchOS, and visionOS Simulator tests
- rejects zero-test and partial-discovery runs with minimum pass counts

### CD

`release.yml`

- runs on bare-semver tag pushes for GA releases
- supports manual `workflow_dispatch` with `tag` and `prerelease=true`
  for `rc` / `beta` pre-releases
- verifies the exact tag, triggering event SHA, `main` ancestry, and tagged
  changelog before starting the macOS build jobs
- serializes all release runs in one publishing queue so two tags cannot deploy
  from the same stale `gh-pages` snapshot
- rebuilds and revalidates the package
- invokes the reusable Apple platform gate and blocks publishing until it passes
- builds versioned DocC output
- requires a valid checkout of the existing `gh-pages` site and fails closed if
  it cannot preserve older released documentation
- merges new docs with existing released docs
- updates `/latest/` only for GA releases
- deploys GitHub Pages
- publishes a GitHub Release named `InnoRouter <version>`

## Documentation source of truth

The repository uses `README + DocC` together.

- `README.md`: overview, quick start, module map, release and CI entry points
- DocC: detailed module guides and API-oriented documentation
- `CLAUDE.md`: maintainer/agent quick reference
- `Docs/v2-principle-scorecard.md`: architecture and quality mapping

Migration guides are intentionally not part of this release process.

## Release checklist

- `CHANGELOG.md` has been cut from `Unreleased` to the release version/date,
  and a new `## Unreleased` section exists above it.
- The `gh-pages` branch contains a root `index.html`; release publication fails
  closed rather than replacing an unavailable site snapshot.
- Public APIs match current README and DocC examples.
- All `.md` files use bare semver tags, not `v`-prefixed tags.
- `Examples/` still match current human-facing API usage.
- `ExamplesSmoke/` still compile and cover the same surface.
- All `.docc` catalogs build locally.
- GitHub `platforms` workflow is green for the release commit. The local
  `./scripts/principle-gates.sh --platforms=all` probe is compile-only.
- `NavigationStore`, `ModalStore`, deep-link, effect, and macro docs reflect current symbols.
- Release notes links point to the current README, RELEASING guide, and DocC portal.
- `xcode-version` in `principle-gates.yml`, `platforms.yml`,
  `release.yml`, `docs-ci.yml`, and `performance-smoke.yml` is
  current — bump to the current release Xcode at release time
  if it has drifted, and re-run `principle-gates.sh` locally with
  the same toolchain.
- Macro tests (`Tests/InnoRouterMacrosTests`,
  `Tests/InnoRouterMacrosBehaviorTests`) execute on macOS (host) only
  — confirm CI runs them on a macOS runner. Linux CI may import
  `InnoRouterMacrosPlugin` for build coverage but cannot expand
  macros without SwiftSyntax host-plugin support.

## GitHub Pages note

The workflow publishes the generated site to GitHub Pages and also keeps the rendered output mirrored in the `gh-pages` branch so versioned documentation can be preserved between releases.
