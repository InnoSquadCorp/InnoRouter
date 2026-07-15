# Macro-first surface contract for 5.0

## Status

This document fixes the 5.0 direction before implementation. InnoRouter may
make source-breaking changes while this contract is implemented. Each surface
must land as a separately verified commit on `main`.

## Goal

An application developer should normally need to learn only three ideas:

1. Declare destinations on an enum with `@Router`.
2. install the matching `Router…Host` at the ownership boundary;
3. read `@EnvironmentRouter(Route.self)` and call named actions.

The macro-first path owns stores locally and chooses safe platform behavior.
Explicit stores, plans, middleware, and coordinators remain the advanced path.

```swift skip proposed 5.0 API
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

RouterHost(AppRoute.self) {
    HomeView()
}

@EnvironmentRouter(AppRoute.self) private var router

router.go(.detail(id: productID))
router.sheet(.profile)
router.dismiss()
```

## Principles

- A route describes destination identity. The action (`go`, `sheet`, or
  `cover`) chooses its presentation, so presentation-only case macros are not
  introduced.
- `RouterHost` is the default stack-plus-modal authority and is backed by one
  `FlowStore`. No environment action may mutate its inner stores directly.
- Compile-time metadata uses macros only when it cannot be inferred safely:
  tabs, URL patterns, and visionOS scene declarations.
- Unsupported declarations fail at compile time with an actionable diagnostic.
  Missing hosts, mismatched route types, unavailable capabilities, and system
  presentation failures use the existing environment/runtime diagnostic
  policy because a declaration macro cannot see a SwiftUI hierarchy.
- Macro support must not expose dispatcher, registry, adapter, or generated
  coordinator implementation types as public API.

## Canonical surfaces

### Stack, modal, and flow

`RouterHost` owns a `FlowStore` and renders navigation plus modal surfaces from
the route's generated destination builder.

```swift skip proposed 5.0 API
RouterHost(
    AppRoute.self,
    initial: [.push(.profile)],
    configuration: flowConfiguration
) {
    HomeView()
}
```

`RouterActions` provides:

- navigation: `go`, `goMany`, `back`, `back(by:)`, `back(to:)`,
  `backToRoot`;
- presentation: `sheet`, `cover`, `dismiss`, `dismissAll`;
- explicit `send` overloads for advanced intent values.

`FlowIntent` gains the navigation and modal parity needed to implement every
named action without reaching into an inner store. `FlowHost` renders internal
environment-free navigation/modal surfaces and registers adapters whose
mutations all pass through `FlowStore`.

`RouterModalHost` is the locally owned modal-only alternative. The existing
`NavigationHost`, `ModalHost`, and `FlowHost` remain externally owned advanced
hosts, but all of them publish the same `EnvironmentRouter` facade.

### Split navigation

On platforms with `NavigationSplitView`, `RouterSplitHost` locally owns the
same flow authority and uses the generated destination builder.

```swift skip proposed 5.0 API
RouterSplitHost(AppRoute.self) {
    Sidebar()
} root: {
    Placeholder()
}
```

The declaration remains visible on watchOS as explicitly unavailable with a
message directing callers to `RouterHost`; it must not fail as an unexplained
missing symbol.

### Tabs

A tab route uses the same `@Router` declaration and adds case-local metadata.

```swift skip proposed 5.0 API
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

When any `@TabItem` is present, `@Router` requires every case to have exactly
one marker and rejects associated values. It generates the iteration and tab
metadata witnesses. `RouterTabHost` owns selection and badge state internally;
the existing `TabCoordinator` API remains the explicit custom-shell path.

### Deep links

Simple path-to-route links use case-local patterns and an explicit origin
allowlist on `@Router`.

```swift skip proposed 5.0 API
@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum AppRoute {
    @DeepLink("/products/:id")
    case product(id: UUID)

    @DeepLink("/settings")
    case settings

    var destination: some View { /* ... */ }
}
```

`@Router` generates a `DeepLinkRoute` mapping only when patterns are present.
`RouterHost` then handles matching URLs automatically and routes the resulting
push through its `FlowStore`. Schemes and hosts are fail-closed literal
allowlists; adding a pattern without a valid allowlist is a compile-time error.

The macro validates literal grammar, duplicate/shadowed patterns, placeholder
labels, associated-value labels, and `DeepLinkParameterValue` compatibility.
Multiple-step `FlowPlan` links, authentication, pending replay, dynamic
patterns, and custom admission remain on the existing explicit matcher and
effect-handler path. Session authority must not be captured in a route enum.

### visionOS scenes

Scene routing is opt-in because a SwiftUI scene tree is statically declared and
has lifecycle rules distinct from stack/modal navigation.

```swift skip proposed 5.0 API
@SceneRouter
enum AppScene {
    @Scene(.window, host: true)
    case main

    @Scene(.volumetric(width: 0.6, height: 0.4, depth: 0.4))
    case model

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View { /* ... */ }
}

@main
struct ExampleApp: App {
    var body: some Scene {
        AppScene.scenes
    }
}

@EnvironmentSceneRouter(AppScene.self) private var scenes
scenes.open(.theatre)
```

`@SceneRouter` is the scene-aware destination macro; applying it together with
`@Router` is an error. It generates the registry, static SwiftUI scene tree,
store ownership, host/anchor wiring, and route-aware scene actions. The macro
rejects associated-value scene cases, duplicate identifiers, invalid sizes or
styles, and missing or multiple primary hosts. Ornament modifiers are not
navigation authorities and stay outside this macro surface.

The umbrella `InnoRouter` product re-exports spatial support so the macro-first
consumer still needs one import. Manual `SceneStore` and scene host/anchor APIs
remain the advanced fallback.

## Diagnostic boundary

Compile-time diagnostics cover facts visible in declarations:

- wrong declaration kind, missing cases, destination witness shape;
- partial or duplicate tab/scene annotations and associated-value misuse;
- malformed, duplicate, shadowed, or incompatible deep-link patterns;
- invalid scene metadata and host cardinality;
- redundant/conflicting manual conformances and generated witnesses.

Runtime diagnostics cover facts visible only after composition:

- host missing or route-type mismatch;
- an action unsupported by the nearest host capability;
- `FlowStore` invariant or middleware rejection;
- platform adaptation such as cover-to-sheet fallback;
- scene system cancellation and lifecycle failures.

The default macro-first host logs actionable flow/platform rejections. Existing
`EnvironmentMissingPolicy` controls fail-fast versus log-and-degrade behavior
for host wiring.

## 5.0 public API policy

Public types are limited to declarations developers write or call directly:
route/scene protocols, macros, named action facades, local hosts, configuration
values, and existing advanced stores/plans/hosts.

Environment storage, dispatcher registration, intent adapters, generated tab
coordinators, generated scene containers, and rendering-only surfaces are
internal. The type-specific `EnvironmentNavigationIntent`,
`EnvironmentModalIntent`, and `EnvironmentFlowIntent` wrappers are replaced by
the single public `EnvironmentRouter`; direct store `send` methods remain the
advanced escape hatch.

## Delivery order

1. Complete `FlowIntent` parity and remove the inner-store policy bypass.
2. Add the unified modal actions and make `RouterHost` flow-backed.
3. Add macro-first split hosting and platform unavailability diagnostics.
4. Add tab metadata generation and `RouterTabHost`.
5. Add generated deep-link mappings and automatic safe-origin handling.
6. Add `@SceneRouter`, generated visionOS scenes, and scene actions.
7. Update diagnostics, examples, README/DocC, API baselines, and all platform
   consumer builds.

Each item is tested and committed before the next item starts. The final push
occurs only after the full package suite, documentation gates, public API gate,
and supported-platform build matrix pass.
