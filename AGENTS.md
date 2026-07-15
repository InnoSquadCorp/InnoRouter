# AGENTS.md

Quick repository guidance for maintainers and coding agents working in InnoRouter.

## Project snapshot

InnoRouter is a SwiftUI-native navigation framework with:

- typed stack state in `InnoRouterCore`
- SwiftUI authority in `InnoRouterSwiftUI`
- opt-in spatial scene authority in `InnoRouterSpatial`
- deep-link parsing and planning in `InnoRouterDeepLink`
- app-boundary execution helpers in `InnoRouterEffects`
- optional route/case-path macros in `InnoRouterMacros`

Requirements:

- iOS 18+
- macOS 15+
- tvOS 18+
- watchOS 11+
- visionOS 2+
- Swift 6.3+

## Common commands

### Runtime and package checks

```bash
swift test
./scripts/principle-gates.sh
```

### DocC

```bash
./scripts/build-docc-site.sh --version preview
```

### Selected build targets

```bash
swift build --target InnoRouter
swift build --target InnoRouterCore
swift build --target InnoRouterSwiftUI
swift build --target InnoRouterSpatial
swift build --target InnoRouterEffects
```

## Module map

### InnoRouterCore

- `Route`, `RouteStack`, `RouteStackValidator`
- `NavigationCommand`, `NavigationEngine`
- `NavigationResult`, `NavigationBatchResult`, `NavigationTransactionResult`
- `Navigator`, `NavigationBatchExecutor`, `NavigationTransactionExecutor`
- `NavigationMiddleware`, `NavigationInterception`, `NavigationCancellationReason`

### InnoRouterSwiftUI

- `NavigationStore`, `NavigationStoreConfiguration`
- `NavigationHost`, `NavigationSplitHost`
- `CoordinatorHost`, `CoordinatorSplitHost`
- `ModalStore`, `ModalStoreConfiguration`, `ModalHost`
- `NavigationIntent`, `ModalIntent`
- `@EnvironmentRouter`, `RouterActions`
- `StepCoordinator`, `TabCoordinator`

### InnoRouterDeepLink

- `DeepLinkMatcher`, `DeepLinkMatcherConfiguration`, diagnostics
- `DeepLinkPipeline`
- `DeepLinkDecision`
- `PendingDeepLink`
- `NavigationPlan`

### InnoRouterSpatial

- `ScenePresentation`, `SceneDeclaration`, `SceneRegistry`
- `SceneStore`, `SceneIntent`, `SceneEvent`
- `innoRouterSceneHost`, `innoRouterSceneAnchor`
- `OrnamentAnchor`, `innoRouterOrnament`
- explicit opt-in product; not re-exported by `InnoRouter`

### InnoRouterEffects

- `NavigationEffectHandler`
- sync `@MainActor` single/batch/transaction helpers
- async boundary helper `executeGuarded`
- `DeepLinkEffectHandler`
- `FlowDeepLinkEffectHandler`
- typed deep-link outcomes
- pending replay helper `resumePendingDeepLinkIfAllowed`

### InnoRouterMacros

- `@Routable`
- `@CasePathable`

## Execution model

### NavigationStore

- `execute(_:)`: single command
- `executeBatch(_:stopOnFailure:)`: per-step execution + one coalesced observer event
- `executeTransaction(_:)`: atomic preview/commit semantics
- `send(_:)`: SwiftUI view intent entry point

### ModalStore

- single current presentation + queued pending presentations
- `sheet` / `fullScreenCover` only
- lifecycle observability through `ModalStoreConfiguration`

### Deep links

- match first
- validate scheme/host
- apply authentication policy
- produce a `NavigationPlan` or a typed non-plan outcome

## Documentation strategy

The repository uses `README + DocC` together.

- `README.md`: repository overview and quick start
- `.docc` catalogs under `Sources/*`: detailed module guides
- `RELEASING.md`: semver release and Pages publishing rules
- `Docs/v2-principle-scorecard.md`: principle and architecture mapping

## Examples policy

- `Examples/`: human-facing examples, macro-first where appropriate
- `ExamplesSmoke/`: compiler-stable smoke fixtures for CI

Both must stay aligned with the same public feature surface.

## Release and Pages policy

- release tags are bare semver only, such as `5.0.0`
- never use a leading `v` in release tags
- a release tag publishes both GitHub Release and versioned DocC
- latest docs live under `/latest/`
- released docs remain available under `/<version>/`

## Documentation gates

`principle-gates.sh` now checks:

- runtime tests
- smoke builds
- DocC preview build
- fail-fast environment probe
- legacy API references in docs
- semver tag formatting in docs
- renamed symbol drift in docs

## Links

- README: [README.md](README.md)
- Release guide: [RELEASING.md](RELEASING.md)
- Scorecard: [Docs/v2-principle-scorecard.md](Docs/v2-principle-scorecard.md)
