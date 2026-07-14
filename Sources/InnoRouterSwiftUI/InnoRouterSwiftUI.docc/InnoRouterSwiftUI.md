# InnoRouterSwiftUI

SwiftUI hosts, stores, modal routing, coordinators, and environment intent dispatch for InnoRouter.

## Overview

`InnoRouterSwiftUI` adapts the core execution model to SwiftUI.

This module owns:

- `NavigationStore`
- `NavigationHost` and `NavigationSplitHost` (watchOS not supported for split host)
- `CoordinatorHost` and `CoordinatorSplitHost` (watchOS not supported for split host)
- `ModalStore` and `ModalHost`
- `NavigationIntent` and `ModalIntent`
- `EnvironmentNavigationIntent` and `EnvironmentModalIntent`
- `StepCoordinator` and `TabCoordinator`
- `SceneDeclaration`, `SceneRegistry`
- `SceneStore`, `SceneHost`, `SceneAnchor` (visionOS only)
- `innoRouterOrnament(_:content:)` view modifier (no-op off visionOS)

The guiding rule is simple: views emit intent, stores own transition authority, and hosts bridge system UI state back into those authorities.

## Choosing a surface

Pick the narrowest authority that matches the app boundary:

| Need | Use |
|---|---|
| One typed SwiftUI stack | `NavigationStore` + `NavigationHost` |
| Split-view stack on supported platforms | `NavigationStore` + `NavigationSplitHost` |
| Sheet / cover authority | `ModalStore` + `ModalHost` |
| Push + modal flows, restoration, or multi-step deep links | `FlowStore` + `FlowHost` + `FlowPlan` |
| visionOS windows, volumes, immersive spaces | `SceneStore` + `SceneHost` / `SceneAnchor` |
| Reducer, effect, or app-boundary execution | `InnoRouterNavigationEffects` / `InnoRouterDeepLinkEffects` |
| Host-less router assertions | `InnoRouterTesting` |

## Platform support

InnoRouter ships on every Apple platform it currently supports:

| Capability | iOS | iPadOS | macOS | tvOS | watchOS | visionOS |
|---|---|---|---|---|---|---|
| `NavigationHost` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `NavigationSplitHost` / `CoordinatorSplitHost` | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| `ModalHost` `.sheet` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `ModalHost` `.fullScreenCover` (native) | ✅ | ✅ | ⚠ degrades to `.sheet` | ✅ | ⚠ degrades to `.sheet` | ⚠ degrades to `.sheet` |
| `TabCoordinator.badge` state API / native visual | ✅ | ✅ | ✅ | ⚠ state only | ⚠ state only | ✅ |
| `SceneStore`, `SceneHost` | — | — | — | — | — | ✅ |
| `innoRouterOrnament` | no-op | no-op | no-op | no-op | no-op | ✅ |

`⚠ state only` means `TabCoordinator` stores and exposes badge state, but
`TabCoordinatorView` omits SwiftUI's native visual badge because `.badge(_:)`
is unavailable on that platform.

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
- <doc:Tutorial-VisionOSScenes>
- <doc:Migration-FromTCA>
- <doc:CaseStudy-OnboardingFlow>

### Guides

- <doc:Guide-SequenceVsBatchVsTransaction>
- <doc:Guide-StepCoordinatorVsFlowStore>
- <doc:Guide-EnvironmentMissingPolicy>
- <doc:Guide-QueueCoalescePolicy>
