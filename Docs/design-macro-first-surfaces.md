# Macro-first surface contract for 5.0

## Status

Implemented on `main`. This document records the 5.0 contract as implemented
and its advanced escape hatches. It is no longer a proposal or delivery
checklist.

## Goal

An application developer normally needs three ideas:

1. Declare destinations on an enum with `@Router`.
2. Install the matching `Router…Host` at the ownership boundary.
3. Read `@EnvironmentRouter(Route.self)` and call named actions.

```swift skip contract-fragment
@Router
enum AppRoute {
    case detail(id: UUID)
    case profile

    var destination: some View {
        switch self {
        case .detail(let id): DetailView(id: id)
        case .profile: ProfileView()
        }
    }
}

RouterHost(AppRoute.self) { HomeView() }

@EnvironmentRouter(AppRoute.self) private var router
router.go(.detail(id: productID))
router.sheet(.profile)
```

The macro-first path owns state locally and chooses documented platform
behavior. Explicit stores, plans, middleware, effects, and coordinators remain
the advanced application-boundary path.

## Principles

- Route cases describe destination identity. Named actions choose push, sheet,
  cover, or tab-selection behavior; presentation-only case macros are not
  needed.
- `RouterHost` owns one `FlowStore`. Every environment mutation goes through
  its unified intent authority, so modal-tail and middleware invariants cannot
  be bypassed through an inner store.
- Compile-time metadata is requested only where it cannot be inferred safely:
  tab labels, URL patterns and origins, and visionOS scene declarations.
- Declaration mistakes receive stable compiler diagnostics. Host wiring,
  capability mismatches, runtime rejection, and scene lifecycle outcomes use
  runtime policy because a macro cannot inspect a SwiftUI hierarchy.
- Generated dispatchers, registries, adapters, containers, and rendering-only
  surfaces remain implementation details rather than public API.

## Canonical surfaces

### Stack plus modal

`RouterHost` owns a local `FlowStore`, renders the generated destination, and
publishes navigation, modal, and flow actions.

```swift skip contract-fragment
RouterHost(
    AppRoute.self,
    initial: [.push(.profile)],
    configuration: flowConfiguration
) {
    HomeView()
}
```

`RouterActions` provides `go`, `goMany`, `back`, `back(by:)`, `back(to:)`,
`backToRoot`, `sheet`, `cover`, `dismiss`, and `dismissAll`. Explicit `send`
overloads remain available for advanced intent values.

`RouterModalHost` is the locally owned modal-only alternative. Externally owned
`NavigationHost`, `ModalHost`, and `FlowHost` publish the same
`EnvironmentRouter` facade for application boundaries that need direct state.

### Split navigation

`RouterSplitHost` owns the detail `FlowStore` authority and generated
destination rendering. Sidebar selection, column visibility, and compact
adaptation stay app-owned.

```swift skip contract-fragment
RouterSplitHost(AppRoute.self) {
    Sidebar()
} root: {
    Placeholder()
}
```

The symbol remains visible but explicitly unavailable on watchOS with a
message directing callers to `RouterHost`.

### Tabs

```swift skip contract-fragment
@Router
enum AppTab {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Profile", systemImage: "person")
    case profile

    var destination: some View {
        switch self {
        case .home: HomeRoot()
        case .profile: ProfileRoot()
        }
    }
}

RouterTabHost(AppTab.self, initial: .home)
```

Once any `@TabItem` appears, every case must carry exactly one annotation and
associated values are rejected. The macro generates `RouterTab`,
`CaseIterable`, and metadata witnesses. `RouterTabHost` owns selection and
badge state; `TabCoordinatorView` remains the custom-shell and external
selection path. tvOS and watchOS retain badge state but omit the unavailable
native visual and emit one privacy-safe warning for the first positive value.

### Deep links

```swift skip contract-fragment
@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum AppRoute {
    @DeepLink("/products/:id")
    case product(id: UUID)

    @DeepLink("/settings")
    case settings

    var destination: some View { /* destination switch */ }
}
```

Generated resolution is fail closed to literal scheme and host allowlists.
Structural precedence is literal, then typed parameter, then terminal
wildcard. Within the same normalized structure, handlers remain ordered so a
failed typed conversion can fall through. A preceding conversion that accepts
every value accepted by a later mapping makes the later mapping unreachable
(`E028`); potentially reachable typed fallbacks emit `W012`.

`RouterHost` and `RouterSplitHost` automatically push one resolved route;
`RouterTabHost` selects one resolved tab. Authentication, pending replay,
dynamic patterns, custom admission, modal style, and multi-step plans remain
on the explicit matcher, pipeline, and Effects path. Session authority is not
captured in a route enum.

### visionOS scenes

Spatial scene routing is an opt-in product because a SwiftUI scene tree is
statically declared and has lifecycle rules distinct from in-window routing.

```swift skip visionos-only
import InnoRouterSpatial

@SceneRouter
enum AppScene {
    @Scene(.window)
    case main

    @Scene(.volumetric(width: 0.6, height: 0.4, depth: 0.4))
    case model

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View { /* destination switch */ }
}

@main
struct ExampleApp: App {
    var body: some Scene { AppScene.scenes }
}

@EnvironmentSceneRouter(AppScene.self) private var scenes
scenes.open(.theatre)
```

The first case becomes the primary host and later cases become lifecycle
anchors. An immersive first case emits `W010` unless the app acknowledges its
external scene-manifest contract with `@SceneRouter(immersiveLaunch: true)`;
an unnecessary acknowledgement emits `W011`. The macro owns generated store,
registry, scene tree, and host/anchor wiring. Manual `SceneStore` composition
is the advanced path for direct event observation or custom ownership.

`InnoRouterSpatial` must be added and imported separately. The default
`InnoRouter` umbrella deliberately does not re-export it.

## Diagnostic boundary

Compile-time diagnostics cover facts visible in declarations:

- declaration kind, cases, and destination witness shape;
- incomplete or duplicate tab/scene annotations and associated-value misuse;
- malformed URL origins and patterns, payload compatibility, generated-member
  conflicts, unreachable mappings, and ordered typed fallbacks;
- invalid scene metadata, identifiers, and immersive-launch acknowledgement;
- redundant or conflicting manual conformances and generated witnesses.

Runtime diagnostics cover facts visible only after composition:

- missing hosts, route-type mismatch, or a capability unsupported by the
  nearest host;
- `FlowStore` invariant or middleware rejection, logged with the owning
  `RouterHost` / `RouterSplitHost` surface name;
- unsupported native tab badge visuals;
- missing scene authority/declaration and scene lifecycle failures.

Cover-to-sheet behavior on macOS, watchOS, and visionOS is an intentional,
documented adaptation. It does not emit an error or warning because it is not
an invalid application of the API.

`EnvironmentMissingPolicy` controls crash versus log-and-degrade behavior for
environment wiring. Scene environment diagnostics lead with generated
`<Route>.scenes` recovery and list manual hosts/anchors as the advanced path.

## Public API policy

Public API is limited to declarations and values developers write, construct,
or call directly: route and scene protocols, macros, named action facades,
local hosts, configuration, advanced stores/plans/hosts, and testing helpers.

Environment storage, authority erasure, dispatcher registration, intent
adapters, generated tab state, generated scene containers, and rendering-only
surfaces stay internal. The single public `EnvironmentRouter` replaces the old
type-specific environment intent wrappers. Direct Store `send` methods remain
the explicit advanced escape hatch.

## Verification contract

The implementation is held by:

- macro expansion and behavior tests for route, tab, deep-link, and scene
  declarations;
- runtime tests for unified authority, automatic URL routing, diagnostics, and
  scene actions;
- one-product downstream consumer smokes for every macro-first host and the
  separate Spatial product;
- public API, DocC, example parity, lint, and supported-platform build gates.

Run `./scripts/principle-gates.sh --platforms=all` for the complete local
compile and package verification contract. Platform runtime tests remain in
the GitHub `platforms` workflow.
