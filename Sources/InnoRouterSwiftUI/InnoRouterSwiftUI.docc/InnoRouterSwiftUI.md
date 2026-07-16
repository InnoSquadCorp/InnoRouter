# InnoRouterSwiftUI

Macro-first SwiftUI routing, externally owned stores, modal routing,
coordinators, and typed `EnvironmentRouter` actions for InnoRouter.

## Overview

`InnoRouterSwiftUI` adapts the core execution model to SwiftUI.

This module owns:

- `DestinationRoute`, `RouterHost`, `RouterModalHost`, `RouterSplitHost`,
  `RouterTabHost`, and `EnvironmentRouter`
- `NavigationStore`
- `NavigationHost` and `NavigationSplitHost` (watchOS not supported for split host)
- `CoordinatorHost` and `CoordinatorSplitHost` (watchOS not supported for split host)
- `ModalStore` and `ModalHost`
- `FlowStore` and `FlowHost`
- `NavigationIntent` and `ModalIntent`
- `RouterActions` and `EnvironmentRouter`
- `RouterTab`, `StepCoordinator`, and `TabCoordinator`

The guiding rule is simple: declare destinations with `@Router`, choose the
local macro-first host for the surface, and let views use
`@EnvironmentRouter`. Promote a store to an application-owned authority only
when authentication-aware deep-link replay, restoration, middleware, direct
observation, or cross-surface policy requires it. Stores own transition
authority, and hosts bridge system UI state back into those authorities.

Spatial scene routing is an opt-in boundary documented by the separate
`InnoRouterSpatial` product. It is not re-exported by the `InnoRouter`
umbrella.

## Choosing a surface

Pick the narrowest authority that matches the app boundary:

| Need | Use |
|---|---|
| Self-contained stack plus sheet / cover | `@Router` + `RouterHost` |
| Self-contained modal-only feature | `@Router` + `RouterModalHost` |
| Self-contained split detail stack plus modal | `@Router` + `RouterSplitHost` |
| Single-route incoming URLs | Add `@DeepLink`; `RouterHost` and `RouterSplitHost` push, while `RouterTabHost` selects |
| Native tabs with host-owned selection and badges | `@Router` + `@TabItem` + `RouterTabHost` |
| Stack with external deep-link, restoration, or middleware authority | `NavigationStore` + `NavigationHost` |
| Split-view stack on supported platforms | `NavigationStore` + `NavigationSplitHost` |
| Sheet / cover authority | `ModalStore` + `ModalHost` |
| Push + modal flows, restoration, or multi-step deep links | `FlowStore` + `FlowHost` + `FlowPlan` |
| Custom app shell with externally owned tab state | `TabCoordinator` + `TabCoordinatorView` |
| visionOS windows, volumes, immersive spaces | Opt in to `@SceneRouter` from `InnoRouterSpatial` |
| Reducer, effect, or app-boundary execution | `InnoRouterEffects` |
| Host-less router assertions | `InnoRouterTesting` |

## Platform support

InnoRouter ships on every Apple platform it currently supports:

| Capability | iOS | iPadOS | macOS | tvOS | watchOS | visionOS |
|---|---|---|---|---|---|---|
| `RouterHost` / `NavigationHost` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `RouterModalHost` / `ModalHost` `.sheet` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `RouterModalHost` / `ModalHost` `.fullScreenCover` (native) | ✅ | ✅ | ⚠ degrades to `.sheet` | ✅ | ⚠ degrades to `.sheet` | ⚠ degrades to `.sheet` |
| `RouterSplitHost` / `NavigationSplitHost` / `CoordinatorSplitHost` | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| `RouterTabHost` / `TabCoordinator` badge state and native visual | ✅ | ✅ | ✅ | ⚠ state only | ⚠ state only | ✅ |

`⚠ state only` means tab selection and badge values remain functional, but the
host omits SwiftUI's unavailable native badge visual. The first positive badge
submitted through `RouterActions`, `RouterTabHost` initial state, or
`TabCoordinator.setBadge` reports one privacy-safe warning on that platform.

## Topics

### Essentials

- <doc:NavigationStore-and-Hosts>
- <doc:Split-Modal-and-Composition>
- <doc:Coordinators-and-Environment-Intent>

### Tutorials

- <doc:Tutorial-LoginOnboarding>
- <doc:Tutorial-DeepLinkReconciliation>
- <doc:Tutorial-MiddlewareComposition>
- <doc:Tutorial-MigratingFromNestedHosts>
- <doc:Tutorial-Throttling>
- <doc:Migration-FromTCA>
- <doc:CaseStudy-OnboardingFlow>

### Guides

- <doc:Migrating-To-InnoRouter-5>
- <doc:Guide-SequenceVsBatchVsTransaction>
- <doc:Guide-StepCoordinatorVsFlowStore>
- <doc:Guide-EnvironmentMissingPolicy>
- <doc:Guide-QueueCoalescePolicy>
