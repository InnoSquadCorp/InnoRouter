# InnoRouterMacros

Build a typed SwiftUI router from an enum while keeping a manual runtime path
available for advanced composition.

## Overview

InnoRouter 5 makes macros part of the canonical `InnoRouter` product. Most
applications add that one product and use one import:

```swift compile
import SwiftUI
import InnoRouter
```

The module exposes three macros with separate responsibilities:

- `@Router` is the default macro-first path. It turns route cases and an
  instance `destination` view into a ``DestinationRoute`` that works with
  ``RouterHost``.
- `@Routable` adds ``Route`` conformance plus typed `Cases`, `is(_:)`, and
  `subscript(case:)` helpers. It does not build destination views.
- `@CasePathable` adds the same case-path helpers without adding `Route`
  conformance.

Every generated conformance has a plain Swift equivalent. Applications that
need externally owned stores, coordinators, restoration, or custom dependency
construction can continue to use the runtime APIs directly.

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

## Advanced granular imports

`import InnoRouter` is the default application entry point. It re-exports the
Core, SwiftUI, deep-link, and macro declarations together.

Use granular products only when a target intentionally needs a narrower graph:

| Product and import | Advanced use case |
|---|---|
| `InnoRouterCore` | Typed route state and command execution without SwiftUI or a compiler-plugin target in this target's build graph. |
| `InnoRouterSwiftUI` | Manually conformed routes, externally owned stores, hosts, and coordinators without a compiler-plugin target in this target's build graph. |
| `InnoRouterDeepLink` | Deep-link matching and planning without the SwiftUI authority layer. |
| `InnoRouterMacros` | A feature target that wants macros plus Core and SwiftUI, but not the deep-link umbrella surface. |
| `InnoRouterSpatial` | visionOS windows, volumes, immersive spaces, and ornaments. This remains opt-in. |

Keeping the compiler-plugin target out of a consumer target's build graph
requires depending on granular runtime products instead of the `InnoRouter`
umbrella. SwiftPM still resolves this package's package-level `swift-syntax`
dependency. Merely omitting a macro attribute from a file does not remove the
umbrella target's macro dependency.

## Topics

### Essentials

- <doc:Router-Macro-First>
- <doc:Routable-and-CasePathable>

### Guides

- <doc:Guide-MacroVisibility>
