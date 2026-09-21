# CI Gates

`scripts/principle-gates.sh` is the single local entry point for the
core release-readiness contract. Every commit landed on `main` is
expected to pass it locally before the PR opens. Cross-device platform runtime
tests remain a GitHub Actions gate because they require iPhone, iPad, tvOS,
watchOS, and visionOS Simulator devices.

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

The `principle-gates` workflow passes `--skip-docc-site` and
`--skip-source-lint` because its required `docs-ci` workflow and sibling lint
job run those same gates. These are CI composition flags, not a reduced local
or release contract. Calling `principle-gates.sh` without them always runs all
gates, and the flags fail unless the orchestrating workflow explicitly sets
`INNOROUTER_DELEGATED_GATES=true`.

Environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SWIFTPM_JOBS` | `2` | `swift test` / `swift build` parallelism |
| `XCODEBUILD_JOBS` | `2` | `xcodebuild` parallelism for Gate 11 |

Hard requirement: `rg` (ripgrep) must be on `PATH`. The script aborts
early with a clear message if it is missing.

## Gates

| # | Gate | Purpose | Local repro |
| --- | --- | --- | --- |
| 1 | `swift test` | Full Swift Testing suite (`Tests/`). | `swift test` |
| 2 | DocC preview build | Rebuilds the three published product catalogs; catches symbol drift and broken cross-refs. | `./scripts/build-docc-site.sh --version preview --skip-latest` |
| 3 | Public API baselines and budgets | Diff against recorded baselines under `Baselines/`, including every umbrella re-export, then enforce a per-product maximum symbol count. Any unrecorded drift or unreviewed growth fails. | `./scripts/check-public-api.sh` |
| 4 | Maintainer docs consistency | 6.0 product/version sync, macro-first entry coverage, exact three-product baselines, and source-definition-to-DocC parity for macro diagnostics. | `./scripts/check-docs-consistency.sh` |
| 5 | Doc Swift code blocks | `swift compile` blocks typecheck against the published API; `swift skip <reason>` blocks must record why they are intentionally excluded. | `./scripts/check-docs-code-blocks.sh` |
| 6 | Macro-first smoke | Compiler-stable `import InnoRouter` fixture covering mixed tab/destination macros, canonical store, links, and snapshots. | `swift build --target InnoRouterMacroFirstSmoke` |
| 7 | Downstream consumer | A nested package imports only the runtime product plus the two optional developer products and runs their canonical tests. | `./scripts/external-consumer-smoke.sh` |
| 8 | Source/workflow lint gates | Forbidden source patterns (`@unchecked Sendable`, `nonisolated(unsafe)`, etc.), file/type/function responsibility budgets, debug-only fences, and invalid GitHub Actions syntax. | `./scripts/lint-source-gates.sh` and `actionlint -config-file .github/actionlint.yaml` |
| 9 | Fail-fast probe | Invoking `EnvironmentRouter` without a matching host must crash deterministically with the documented message. | `swift run RouterEnvironmentFailFastProbe` (expected to fail) |
| 10 | Public Bool naming | Public `Bool` properties must start with `is`, `has`, `can`, or `should`. | `rg "public (var\|let) [A-Za-z_][A-Za-z0-9_]*: Bool" Sources` |
| 11 | Per-platform interface probe (optional) | Two isolated workspace consumers jointly compile all three public library products with library evolution against each Apple-platform generic destination, including Mac Catalyst, then validate the emitted interfaces. | `./scripts/principle-gates.sh --platforms=all` |

## `--platforms=` flag

Accepted tokens (lowercase, comma- or space-separated):

```
all  ios  ipados  maccatalyst  macos  tvos  watchos  visionos
```

Rules:

- Empty value (`--platforms=`) is rejected.
- `all` cannot be combined with explicit names — `--platforms=all,ios`
  is rejected to keep the flag unambiguous.
- Each requested platform invokes `xcodebuild build` for
  `InnoRouterMacroFirstSmoke` and `InnoRouterDeveloperToolsSmoke` in the
  explicit platform-test workspace. Together they import all three public
  library products. The macro fixture is an actual one-product consumer, not only a
  declaration build. An isolated DerivedData path prevents an unrelated local
  Xcode project from influencing package resolution.
- Release library-evolution interfaces are validated against
  `Baselines/PlatformAPI/targets.tsv`: the target triple must preserve the
  declared deployment floor, all three products must emit a public interface,
  the umbrella export graph must be complete, and retired 5.x surfaces must
  remain absent.
- iOS and iPadOS intentionally map to the same generic iOS Simulator
  destination. When both are requested, the local script builds that
  destination once rather than claiming two distinct compile probes.
- `xcodebuild` must be available; the gate aborts otherwise.
- This flag is compile/interface-only. It does not replace the runtime tests in
  the GitHub `platforms` workflow.

## CI workflow mapping

Every gate above runs under one of the workflows in `.github/workflows/`:

| Workflow | Gates |
| --- | --- |
| `principle-gates.yml` | 1–10 plus public-API / `Unreleased` changelog sync (every PR / push to `main` and `develop`) |
| `platforms.yml` | 11 (runtime and developer-tool consumers covering all three public library products on every Apple platform), library-evolution interface validation against each platform floor, plus iPhone, iPad, tvOS, watchOS, and visionOS runtime tests with minimum executed-test counts; macOS runs the same shared contract in Gate 1 |
| `docs-ci.yml` | 2 (DocC build validation) |
| `coverage.yml` | 1 with coverage instrumentation, a repository-owned 85% line floor, and Codecov relative project/patch checks |
| `performance-smoke.yml` | isolated 10/50/100-case `@Routable` expansion plus seven release-mode reducer, snapshot, deep-link, Inspector, scenario-capture, history-capacity, and catalog-size baselines with an uploaded JSON trend artifact |
| `sanitizers.yml` | focused reducer/store/event-stream Thread Sanitizer and lifecycle/input Address Sanitizer jobs |
| `migration-smoke.yml` | builds the exact published 5.2.1 downstream fixture, builds its macro-first 6.0 migration against the checkout, and compares final behavior |
| `release.yml` | verifies the exact tag and changelog, reruns 1–10, calls the reusable platform, coverage, sanitizer, performance, and migration workflows, then serially merges versioned DocC into the required existing Pages site and publishes the GitHub Release; `/latest/` advances monotonically by GA SemVer |

### SwiftPM resolution and cache decision

The root, external consumer, both migration fixtures, and the native Xcode
workspace track `Package.resolved` for repository CI reproducibility. These
files do not constrain applications that consume InnoRouter as a dependency.

A dependency-only `actions/cache` candidate was measured with exact runner,
toolchain, SDK, architecture, manifest, and resolution keys. Three warm
principle-gate runs had a 761-second median for the core step versus the
712-second no-cache baseline, a 6.9% regression. DocC, coverage, migration,
performance, and sanitizer measurements also showed no consistent benefit.
The cache was therefore removed rather than expanding it to product binaries or
weakening its key. CI rebuilds every gate from the tracked resolution. See
GitHub's [dependency cache reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
for the cache behavior evaluated here.

Tag format is bare semver (`6.0.0`) — leading-`v` or prefixed semver tags
are rejected by the regex in `release.yml`.

### Coverage contract

`coverage.yml` generates a gated LCOV report for deterministic production logic,
validates the report structure, and fails below **85% line coverage** before
any network upload. Codecov then applies the relative project and patch rules in
`.github/codecov.yml`; an upload error also fails the workflow so a missing
external status cannot silently bypass the repository-owned floor.

The same instrumented run also exports `coverage-full.lcov` with all library
source modules visible, including native hosts and macro bootstrap code. That
comprehensive report does not replace the portable 85% numerical floor; a
component-level `coverage-summary.json` and both LCOV files are retained as CI
artifacts so excluded host code cannot disappear from review.

The host numerical report intentionally excludes SwiftUI render adapters,
native scene-lifecycle bridges, the Inspector view and scenario UI section, the compiler-plugin
bootstrap entry point, and the byte-identical macro-host route-pattern copy.
Those paths are covered by `platforms.yml`, downstream consumer builds,
fail-fast probes, source-parity checks, and shared native-host runtime tests.
Core reduction, scheduling, policy, restoration, deep-link matching, inspector
models, macro expansion, and `InnoRouterTesting` remain inside the 85% floor.
The exact auditable exclusion list lives only in
`scripts/generate-coverage-report.sh`.

Reproduce the same report and deterministic checks locally with:

```bash
swift test --enable-code-coverage --jobs 2
./scripts/generate-coverage-report.sh coverage.lcov coverage-full.lcov
./scripts/test-validate-coverage-report.sh
./scripts/test-summarize-coverage-report.sh
./scripts/validate-coverage-report.py coverage.lcov --minimum-line-coverage 85
./scripts/validate-coverage-report.py coverage-full.lcov --minimum-line-coverage 0
./scripts/summarize-coverage-report.py --gated coverage.lcov --comprehensive coverage-full.lcov --output coverage-summary.json
```

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
   in `scripts/check-public-api.sh`, review the diff, and update the independent
   symbol budget only when the growth itself is intentional.

## See also

- [`RELEASING.md`](../RELEASING.md) — tag/release flow that reruns this script.
- [`Docs/v6-functional-strategy.md`](v6-functional-strategy.md) — the product principles that motivate the gates.
- [`Docs/v6-public-api-boundary.md`](v6-public-api-boundary.md) — the macro-first facade, canonical advanced layer, and API budget policy.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — when to run `principle-gates.sh` during development.
