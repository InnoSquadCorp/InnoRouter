# Macro-first routing with `@Router`

@Metadata {
  @PageKind(article)
}

Declare route data and destination views in one enum, then select the host that
matches the surface. Stack, modal, split, tab, and single-route deep-link
handling all keep the same `@EnvironmentRouter` action API.

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

## Choose a host

The host owns local state. Start with the narrowest host that covers the
feature:

| Surface | Macro-first host | Common actions from `@EnvironmentRouter` |
|---|---|---|
| Stack plus modal | `RouterHost` | `go`, `back`, `sheet`, `cover`, `dismiss` |
| Modal only | `RouterModalHost` | `sheet`, `cover`, `dismiss` |
| Split detail stack plus modal | `RouterSplitHost` | `go`, `back`, `sheet`, `cover`, `dismiss` |
| Native tabs | `RouterTabHost` | `select`, `setBadge`, `clearBadge` |

Promote state to a `NavigationStore`, `ModalStore`, `FlowStore`, or
`TabCoordinator` only when another application boundary must restore, observe,
or mutate that authority directly.

## Stack and modal routing

Use `RouterHost` for the common stack-plus-modal surface:

```swift skip surrounding view declaration
RouterHost(LibraryRoute.self) {
    LibraryHomeView()
}
```

Descendants read typed actions from `EnvironmentRouter`:

```swift skip surrounding view declaration
@EnvironmentRouter(LibraryRoute.self) private var router

Button("Account") {
    router.go(.account)
}

Button("Account sheet") {
    router.sheet(.account)
}
```

Use `RouterModalHost` when the feature must not expose stack actions:

```swift skip surrounding view declaration
RouterModalHost(LibraryRoute.self) {
    LibraryHomeView()
}
```

Generated `@DeepLink` routes present as sheets automatically in this host. Pass
`deepLinkStyle: .fullScreenCover` when the entire modal-only feature uses cover
presentation for incoming URLs.

Calling an action unsupported by the nearest host, such as `go` below a
modal-only host, follows `EnvironmentMissingPolicy` and fails loudly by
default.

## Split routing

Use `RouterSplitHost` for a sidebar with a locally owned detail stack and modal
authority:

```swift skip surrounding view declaration
RouterSplitHost(LibraryRoute.self) {
    LibrarySidebar()
} root: {
    ContentUnavailableView("Select a book", systemImage: "books.vertical")
}
```

Sidebar selection and column visibility remain application and system state;
routes pushed from descendants appear in the detail column. `RouterSplitHost`
is unavailable on watchOS, where the compiler directs callers to `RouterHost`.

## Native tabs

Mark every parameterless case with `@TabItem`. `@Router` then supplies
`RouterTab`, `CaseIterable`, and the metadata consumed by `RouterTabHost`:

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppTab {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Account", systemImage: "person")
    case account

    var destination: some View {
        switch self {
        case .home:
            Text("Home")
        case .account:
            Text("Account")
        }
    }
}

struct AppTabs: View {
    var body: some View {
        RouterTabHost(AppTab.self, initial: .home)
    }
}

struct AccountShortcut: View {
    @EnvironmentRouter(AppTab.self) private var router

    var body: some View {
        Button("Account") {
            router.select(.account)
            router.setBadge(1, for: .account)
        }
    }
}
```

## Automatic single-route deep links

Give `@Router` literal origin allowlists and attach `@DeepLink` to the cases
that accept URLs:

```swift compile
import SwiftUI
import InnoRouter

@Router(
    deepLinkSchemes: ["myapp", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum DeepLinkRoute {
    @DeepLink("/books/:id")
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

struct DeepLinkRoot: View {
    var body: some View {
        RouterHost(DeepLinkRoute.self) {
            Text("Library")
        }
    }
}
```

No `onOpenURL` or parser is needed for this single-route path:

- `RouterHost` pushes the resolved route.
- `RouterSplitHost` pushes it into the detail stack.
- `RouterModalHost` presents it with its configured style (`.sheet` by default).
- `RouterTabHost` selects the resolved tab.

Origin allowlists fail closed. Generated matching prefers literal paths, then
typed parameters, then terminal wildcards. Authentication, pending replay,
multi-step plans, per-route presentation policy, and multi-window scene
selection remain application-boundary concerns; use the deep-link pipeline and
an externally owned store for those advanced policies.

## Diagnostics

The macros reject invalid declaration shapes before emitting a partial
conformance. Diagnostic codes are stable and grouped by surface:

- `E001`–`E006`, `W001`–`W003`: enum and destination declarations
- `E007`–`E016`, `W004`–`W005`: tabs
- `E017`–`E029`, `W006`–`W007`, `W012`: deep links
- `E030`–`E049`, `W008`–`W011`: opt-in spatial scenes

See <doc:Macro-Diagnostics> for the complete code-to-recovery catalog.

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

The macro cannot prove that a view is mounted below a matching host or that the
host publishes the action being invoked because SwiftUI's environment
hierarchy is built at runtime. `EnvironmentRouter` therefore diagnoses a
missing host, mismatched route type, or unavailable capability at action time.

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

This path keeps the same `RouterHost` and `EnvironmentRouter` runtime
semantics; only the generated declaration work becomes explicit.
