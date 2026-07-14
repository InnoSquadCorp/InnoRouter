# Macro-first routing with `@Router`

@Metadata {
  @PageKind(article)
}

Declare route data and destination views in one enum, then let `@Router` supply
the SwiftUI routing conformance.

## Declare a router

Add the `InnoRouter` product and use the canonical imports:

Attach `@Router` to an enum with at least one route case and one get-only
instance computed property whose exact declaration shape is
`var destination: some View`:

```swift compile
import SwiftUI
import InnoRouter

@Router
enum LibraryRoute {
    case book(id: String)
    case account

    var destination: some View {
        switch self {
        case .book(let id):
            Text("Book \(id)")
        case .account:
            Text("Account")
        }
    }
}
```

Do not add `: Route` or `: DestinationRoute`. `@Router` supplies
`DestinationRoute`, which already refines `Route`, `Hashable`, and `Sendable`.

## What the macro generates

When the `destination` property is valid, `@Router` adds `@MainActor` and
`@ViewBuilder` unless they are already present. It also emits the equivalent of:

```swift skip generated expansion
extension LibraryRoute: InnoRouterSwiftUI.DestinationRoute {
    @Swift.MainActor
    @SwiftUI.ViewBuilder
    static func destination(for route: Self) -> some SwiftUI.View {
        route.destination
    }
}
```

The generated witness follows the enum's effective access level. A public
route can therefore keep its instance `destination` hook private while the
protocol witness remains public.

`@Router` does not generate case paths. When a macro-first router also needs
typed case extraction, compose it with `@CasePathable`:

```swift compile
import SwiftUI
import InnoRouter

@Router
@CasePathable
enum SearchRoute {
    case result(id: String)

    var destination: some View {
        Text("Result")
    }
}

let route = SearchRoute.result(id: "42")
route[case: SearchRoute.Cases.result]  // Optional("42")
```

## Host and navigate

Use ``RouterHost`` when the navigation store is local to the view tree:

```swift skip surrounding view declaration
RouterHost(LibraryRoute.self) {
    LibraryHomeView()
}
```

Descendants read typed actions from ``EnvironmentRouter``:

```swift skip surrounding view declaration
@EnvironmentRouter(LibraryRoute.self) private var router

Button("Account") {
    router.go(.account)
}
```

Use ``NavigationHost`` with an externally owned store when restoration,
deep-link reconciliation, middleware mutation, or external observation needs
to outlive the local host.

## Diagnostics

The macro rejects invalid declaration shapes before emitting a partial
conformance. Diagnostic codes are stable so build logs can link to a specific
recovery path.

| Code | Severity | Meaning and recovery |
|---|---|---|
| `InnoRouterMacro.E001` | Error | `@Router` is not attached to an enum. Structs and classes receive a change-to-enum Fix-It; actors and protocols receive a manual-refactor note. |
| `InnoRouterMacro.E004` | Error | The enum has no `destination` property. Declare it directly inside the enum. A property in a separate extension is outside the attached macro's syntax scope. |
| `InnoRouterMacro.E005` | Error | The property is not a get-only instance computed `var destination: some View` in its own declaration. Correct the shape reported in the diagnostic. |
| `InnoRouterMacro.E006` | Error | A manual `static destination(for: Self)` witness conflicts with the generated witness. Remove that function, or remove `@Router` and conform manually; overloads for other parameter types remain valid. |
| `InnoRouterMacro.W001` | Warning | The enum has no route cases. This is valid for a root-only host, but no destination can be pushed. |
| `InnoRouterMacro.W002` | Warning | The enum explicitly declares `DestinationRoute`; remove the redundant conformance and let `@Router` supply it. |
| `InnoRouterMacro.W003` | Warning | The enum explicitly declares `Route`; remove it because the generated `DestinationRoute` already inherits `Route`. |

The Swift type checker remains responsible for view initializer arguments,
exhaustive switching, and `Hashable` / `Sendable` payload requirements. A
constrained generic router is supported when its payload meets those route
requirements:

```swift compile
import SwiftUI
import InnoRouter

@Router
enum DetailRoute<Value: Hashable & Sendable> {
    case detail(Value)

    var destination: some View {
        Text("Detail")
    }
}
```

The macro cannot prove that a view is mounted below the matching host because
SwiftUI's environment hierarchy is built at runtime. ``EnvironmentRouter``
therefore preserves InnoRouter's existing missing-host and mismatched-route
runtime diagnostics.

## Manual escape hatch

Advanced targets can keep the compiler-plugin target out of their build graph
by depending on the granular `InnoRouterSwiftUI` product and writing the
conformance directly:

```swift compile
import SwiftUI
import InnoRouterSwiftUI

enum ManualRoute: DestinationRoute {
    case settings

    @MainActor
    @ViewBuilder
    static func destination(for route: Self) -> some View {
        switch route {
        case .settings:
            Text("Settings")
        }
    }
}
```

This path keeps the same ``RouterHost`` and ``EnvironmentRouter`` runtime
semantics; only the generated declaration work becomes explicit.
