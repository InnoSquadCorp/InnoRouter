# InnoRouterSwiftUI

Macro-first SwiftUI routing, externally owned stores, modal routing,
coordinators, and typed `EnvironmentRouter` actions for InnoRouter.

## Overview

`InnoRouterSwiftUI` adapts the core execution model to SwiftUI.

This module owns:

- `DestinationRoute`, `RouterHost`, `RouterTabHost`, and `EnvironmentRouter`
- `NavigationStore`
- `NavigationHost` and `NavigationSplitHost` (watchOS not supported for split host)
- `CoordinatorHost` and `CoordinatorSplitHost` (watchOS not supported for split host)
- `ModalStore` and `ModalHost`
- `NavigationIntent` and `ModalIntent`
- `RouterActions` and `EnvironmentRouter`
- `RouterTab`, `StepCoordinator`, and `TabCoordinator`

The guiding rule is simple: start with `@Router` + `RouterHost`, let views use
`@EnvironmentRouter`, and promote the `NavigationStore` to an application-owned
authority only when deep links, restoration, middleware, or cross-surface
composition require it. Stores own transition authority, and hosts bridge
system UI state back into those authorities.

Spatial scene routing is an opt-in boundary documented by the separate
`InnoRouterSpatial` product. It is not re-exported by the `InnoRouter`
umbrella.

## Choosing a surface

Pick the narrowest authority that matches the app boundary:

| Need | Use |
|---|---|
| One self-contained typed SwiftUI stack | `@Router` + `RouterHost` |
| Stack with external deep-link, restoration, or middleware authority | `NavigationStore` + `NavigationHost` |
| Split-view stack on supported platforms | `NavigationStore` + `NavigationSplitHost` |
| Sheet / cover authority | `ModalStore` + `ModalHost` |
| Push + modal flows, restoration, or multi-step deep links | `FlowStore` + `FlowHost` + `FlowPlan` |
| Native tabs with host-owned selection and badges | `@Router` + `@TabItem` + `RouterTabHost` |
| Custom app shell with externally owned tab state | `TabCoordinator` + `TabCoordinatorView` |
| visionOS windows, volumes, immersive spaces | Opt in to `InnoRouterSpatial` |
| Reducer, effect, or app-boundary execution | `InnoRouterEffects` |
| Host-less router assertions | `InnoRouterTesting` |

## Platform support

InnoRouter ships on every Apple platform it currently supports:

| Capability | iOS | iPadOS | macOS | tvOS | watchOS | visionOS |
|---|---|---|---|---|---|---|
| `RouterHost` / `NavigationHost` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `NavigationSplitHost` / `CoordinatorSplitHost` | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| `ModalHost` `.sheet` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `ModalHost` `.fullScreenCover` (native) | ✅ | ✅ | ⚠ degrades to `.sheet` | ✅ | ⚠ degrades to `.sheet` | ⚠ degrades to `.sheet` |
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
- <doc:Tutorial-StoreObserver>
- <doc:Migration-FromTCA>
- <doc:CaseStudy-OnboardingFlow>

### Guides

- <doc:Guide-SequenceVsBatchVsTransaction>
- <doc:Guide-StepCoordinatorVsFlowStore>
- <doc:Guide-EnvironmentMissingPolicy>
- <doc:Guide-QueueCoalescePolicy>
