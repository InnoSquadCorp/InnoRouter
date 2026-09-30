# InnoRouterMacros

Build a typed SwiftUI router from an enum while keeping a manual runtime path
available for advanced composition.

## Overview

InnoRouter 6 makes macros part of the canonical `InnoRouter` product. Most
applications add that one product and use one import:

```swift compile
import SwiftUI
import InnoRouter
```

The module exposes eight macros with separate responsibilities:

- `@Router` is the default macro-first path. It turns route cases and an
  instance `destination` view into a `DestinationRoute` that works with
  `RouterHost`, and generates tab or deep-link capabilities when their marker
  macros are present.
- `@TabItem` marks parameterless router cases and generates the metadata used
  by `RouterTabHost`.
- `@DeepLink` maps literal URL paths to typed router cases. `@Router` validates
  literal scheme and host allowlists and generates the `DeepLinkRoute`
  resolver. Generated matching prefers literal paths, then typed parameters,
  then terminal wildcards, regardless of case declaration order.
- `@Scene` marks parameterless routes that can be opened through the generated
  scene catalog and `RouterSceneDriver`.
- `@FeatureRoute` generates one bidirectional child-route mapping while the
  parent `RouterStore` remains the only mutable authority. Recursive child
  payloads may use the enclosing route's `Self`, including nested generic
  routers.
- `@PresentationResult` generates typed presentation requests so presentation
  completion values are checked at compile time.
- `@Routable` adds `Route` conformance plus typed `Cases`, `is(_:)`, and
  `subscript(case:)` helpers. It does not build destination views.
- `@CasePathable` adds the same case-path helpers without adding `Route`
  conformance.

Every generated conformance has a plain Swift equivalent. Applications that
need externally owned stores, restoration, or custom dependency construction
can continue to use the runtime APIs directly.

## Macro-first quick start

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case detail(id: String)
    case settings

    var destination: some View {
        switch self {
        case .detail(let id):
            Text("Detail \(id)")
        case .settings:
            Text("Settings")
        }
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) {
            HomeView()
        }
    }
}

struct HomeView: View {
    @EnvironmentRouter(AppRoute.self) private var router

    var body: some View {
        Button("Open settings") {
            router.go(.settings)
        }
    }
}
```

`@Router` supplies `Route` through `DestinationRoute`, so do not add either
conformance to `AppRoute`. The `switch` remains ordinary Swift and receives the
compiler's exhaustive-case checking.

## Products

`import InnoRouter` is the application entry point. Core, SwiftUI, deep-link,
system-surface, and macro implementation modules are package internals rather
than alternate product choices.

| Product and import | Advanced use case |
|---|---|
| `InnoRouter` | Macro-first runtime, hosts, deep links, scenes, App Intents, Handoff, and platform bridges. |
| `InnoRouterInspector` | Opt-in debug inspector, redacted state tree, diffs, export, and safe replay preview. |
| `InnoRouterTesting` | Host-less `RouterTestStore` assertions for route state transitions. |

## Topics

### Essentials

- <doc:Router-Macro-First>
- <doc:Routable-and-CasePathable>

### Guides

- <doc:Guide-MacroVisibility>
- <doc:Macro-Diagnostics>
