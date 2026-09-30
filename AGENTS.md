# Maintainer guide

InnoRouter 6 is a macro-first typed navigation framework for SwiftUI.

## Public contract

A normal app imports the single `InnoRouter` runtime product, declares one
`@Router` enum, and renders it with `RouterHost`, `RouterTabHost`, or
`RouterSplitHost`.

- `RouterState<Route>` is the complete navigation value.
- `RouterAction<Route>` is the only incremental request language.
- `RouterPlan<Route>` is the exact-state value shared by links and restore.
- `RouterStore<Route>` is the only mutable authority at a host boundary.
- `RouterScope<Route>` is a read-only subtree projection and action forwarder.

The only selectable public library products are:

- `InnoRouter`
- `InnoRouterTesting`
- `InnoRouterInspector`

The 5.x stores, intents, effects, scenes, and regression sources remain
available in Git history only. They are absent from the working source tree and
package build graph. Do not restore them to active targets or use them in new
examples, public docs, or API.

## Requirements

- Swift 6.3+
- iOS/iPadOS 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

## Common commands

```bash
swift test --jobs 2 --no-parallel
./scripts/principle-gates.sh
./scripts/principle-gates.sh --platforms=all
./scripts/build-docc-site.sh --version preview --skip-latest
./scripts/external-consumer-smoke.sh
```

`--no-parallel` is required, not optional. `RouterSnapshotStorage` is a
synchronous protocol by design, so the restoration suites' storage doubles
hold a real thread inside `load()`/`save()` to keep an operation open. Swift
Testing runs suites concurrently in-process by default, and enough
simultaneously blocked doubles starve the cooperative pool: the restoration
tests then fail with 60s time-limit and `loadTimedOut` errors. The gates in
`scripts/principle-gates.sh` and `.github/workflows/coverage.yml` already pass
this flag.

## Architecture rules

1. Add navigation state to the recursive `RouterState` tree instead of creating
   another store type.
2. Add incremental behavior as `RouterAction` plus a pure `RouterReducer`
   transition.
3. Policies inspect immutable candidates. They do not mutate router or business
   state across `await`.
4. An accepted transition performs one complete state assignment and one
   revision increment. A rejected transition performs neither.
5. Deep links, restoration, and transactions converge on `RouterPlan`.
6. Hosts render native SwiftUI containers over one store. A child scope never
   owns parallel mutable navigation state.
7. Inspector output is structurally useful and payload-redacted by default.

## Macro rules

- `@Router` is the default declaration path and requires expansion plus runtime
  behavior coverage.
- `@TabItem` marks parameterless tab roots; unmarked cases remain destinations.
- `@Scene` marks parameterless window or immersive routes on the same router.
- `@PresentationResult` generates a typed request shared by present and finish.
- `@FeatureRoute` composes an independent feature's route enum into a parent
  router without a second store.
- `@DeepLink` must remain fail closed for origins and malformed input.
- `@Routable` and `@CasePathable` are advanced supporting macros, not a second
  router architecture.

Macro changes require tests in both `Tests/InnoRouterMacrosTests/` and
`Tests/InnoRouterMacrosBehaviorTests/`.

## Documentation and examples

- `README.md` and `README.ko.md` are the canonical quick starts.
- `Sources/InnoRouterUmbrella/InnoRouter.docc/` is the public runtime catalog.
- `Docs/v6-functional-strategy.md` states product decisions.
- `Docs/functional-expansion-spec.md` states requirements and acceptance.
- `Examples/` contains copyable macro-first examples.
- `ExamplesSmoke/` and `ConsumerSmoke/` verify compiler and downstream product
  boundaries.
- `Docs/Archive/5.x/` is historical evidence only and must not define current
  behavior.

## Release rules

- Tags are bare SemVer, such as `6.0.0`; never prefix them with `v`.
- Update only the three public API baselines intentionally.
- Breaking changes after 6.0 target the next major release.
- A release requires package, macro, DocC, public API, lint, platform, and exact
  downstream revision gates.

## Links

- [README](README.md)
- [6.0 strategy](Docs/v6-functional-strategy.md)
- [6.0 specification](Docs/functional-expansion-spec.md)
- [6.0 delivery plan](Docs/functional-expansion-technical-plan.md)
- [Release guide](RELEASING.md)
