# CI Gates

`scripts/principle-gates.sh` is the single local entry point for the
core release-readiness contract. Every commit landed on `main` is
expected to pass it locally before the PR opens. Platform runtime tests
remain a GitHub Actions gate because they require tvOS, watchOS, and
visionOS Simulator runtimes.

This document covers what each gate enforces, the failure signal
operators see, and how to reproduce a single gate without running
the whole pipeline.

## Quick reference

```bash
# Core pipeline — used in CI and on tag pushes.
./scripts/principle-gates.sh

# Full pipeline + per-platform xcodebuild compile probe.
./scripts/principle-gates.sh --platforms=all
./scripts/principle-gates.sh --platforms=ios,macos
```

Environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SWIFTPM_JOBS` | `2` | `swift test` / `swift build` parallelism |
| `XCODEBUILD_JOBS` | `2` | `xcodebuild` parallelism for Gate 13 |

Hard requirement: `rg` (ripgrep) must be on `PATH`. The script aborts
early with a clear message if it is missing.

## Gates

| # | Gate | Purpose | Local repro |
| --- | --- | --- | --- |
| 1 | `swift test` | Full Swift Testing suite (`Tests/`). | `swift test` |
| 2 | DocC preview build | Rebuilds every `.docc` catalog; catches symbol drift and broken cross-refs. | `./scripts/build-docc-site.sh --version preview --skip-latest` |
| 3 | Public API baselines | Diff against recorded baselines under `Baselines/`. Any unrecorded addition, removal, or rename fails. | `./scripts/check-public-api.sh` |
| 4 | Maintainer docs consistency | README / CLAUDE.md / AGENTS.md / RELEASING.md / CHANGELOG.md cross-reference and version-string sync. | `./scripts/check-docs-consistency.sh` |
| 5 | Doc Swift code blocks | `swift compile` blocks typecheck against the published API; `swift skip <reason>` blocks must record why they are intentionally excluded. | `./scripts/check-docs-code-blocks.sh` |
| 6 | Examples ↔ ExamplesSmoke parity | 1:1 file alignment between the two example trees. See `Examples/README.md` for which side to edit. | `./scripts/check-examples-parity.sh` |
| 7 | Smoke targets build | Compiler-stable fixtures plus a one-product downstream default-umbrella check for every core macro-first host. | `swift build --target InnoRouterExamplesSmoke`, `swift build --target InnoRouterMacroFirstSmoke`, and siblings |
| 8 | Human-facing examples build | Macro-first entry examples and explicitly advanced Store / Coordinator examples in `Examples/`. | `swift build --target InnoRouterStandaloneExample` (and siblings) |
| 9 | Performance smoke | Coarse timing budget for engine dispatch / command algebra. | `./scripts/performance-smoke.sh` |
| 10 | Source/workflow lint gates | Forbidden source patterns (`@unchecked Sendable`, `nonisolated(unsafe)`, etc.), debug-only fences, and invalid GitHub Actions syntax. | `./scripts/lint-source-gates.sh` and `actionlint -config-file .github/actionlint.yaml` |
| 11 | Fail-fast probe | Invoking `EnvironmentRouter` without a matching host must crash deterministically with the documented message — guards against silent fallback regressions. | `swift run RouterEnvironmentFailFastProbe` (expected to fail) |
| 12 | Public Bool naming | Public `Bool` properties must start with `is`, `has`, `can`, or `should`. | `rg "public (var\|let) [A-Za-z_][A-Za-z0-9_]*: Bool" Sources` |
| 13 | Per-platform compile probe (optional) | `xcodebuild` against each Apple-platform generic destination, including the core macro-first consumer and the separate Spatial consumer on visionOS. Only runs when `--platforms=…` is passed. | `./scripts/principle-gates.sh --platforms=all` |

## `--platforms=` flag

Accepted tokens (lowercase, comma- or space-separated):

```
all  ios  ipados  macos  tvos  watchos  visionos
```

Rules:

- Empty value (`--platforms=`) is rejected.
- `all` cannot be combined with explicit names — `--platforms=all,ios`
  is rejected to keep the flag unambiguous.
- Each requested platform invokes `xcodebuild build` for all eight public
  product schemes and `InnoRouterMacroFirstSmoke` against the selected generic
  destination. The smoke is an actual one-product macro consumer, not only a
  macro declaration build. Generic destinations avoid drift between local
  toolchains and CI runners.
- The visionOS destination additionally builds
  `InnoRouterSpatialConsumerSmoke`, which depends only on
  `InnoRouterSpatial` and expands the generated scene tree and actions.
- iOS and iPadOS intentionally map to the same generic iOS Simulator
  destination. When both are requested, the local script builds that
  destination once rather than claiming two distinct compile probes.
- `xcodebuild` must be available; the gate aborts otherwise.
- This flag is compile-only. It does not replace the runtime tests in
  the GitHub `platforms` workflow.

## CI workflow mapping

Every gate above runs under one of the workflows in `.github/workflows/`:

| Workflow | Gates |
| --- | --- |
| `principle-gates.yml` | 1–12 plus public-API / `Unreleased` changelog sync (every PR / push to `main` and `develop`) |
| `platforms.yml` | 13 (all eight public products plus the macro-first consumer on every Apple platform), a visionOS Spatial consumer build, plus tvOS, watchOS, and visionOS runtime tests with minimum executed-test counts |
| `docs-ci.yml` | 2 (DocC build validation) |
| `coverage.yml` | 1 (with coverage instrumentation) |
| `performance-smoke.yml` | 9 (perf regression detection) |
| `release.yml` | verifies the exact tag and changelog, reruns 1–12, calls the reusable `platforms` workflow, then serially merges versioned DocC into the required existing Pages site and publishes the GitHub Release; `/latest/` advances monotonically by GA SemVer |

Tag format is bare semver (`5.0.0`) — leading-`v` or prefixed semver tags
are rejected by the regex in `release.yml`.

## When a gate fails

Default response order:

1. Re-read the failing gate's purpose above.
2. Reproduce locally with the single command in the table — most
   gates run in a few seconds independently.
3. If the failure is genuine, fix the underlying cause rather than
   the symptom. Bypassing a gate (`--no-verify`, environment
   override) is not the intended workflow.
4. If the failure is a baseline drift (Gate 3) caused by a deliberate API
   change, regenerate the baseline through the dedicated helper documented
   in `scripts/check-public-api.sh` and review the diff before committing it.

## See also

- [`RELEASING.md`](../RELEASING.md) — tag/release flow that reruns this script.
- [`Docs/v2-principle-scorecard.md`](v2-principle-scorecard.md) — the principles that motivate the gates.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — when to run `principle-gates.sh` during development.
