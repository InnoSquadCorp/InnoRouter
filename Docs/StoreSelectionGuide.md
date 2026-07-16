# Surface Selection Guide

InnoRouter 5.0 is macro-first. Most features declare a route enum, install a
locally owned host, and call typed environment actions. Stores remain public
for application boundaries that must own, restore, observe, or mutate routing
state directly; they are not prerequisite setup for an ordinary feature.

The filename remains `StoreSelectionGuide.md` so existing links stay stable,
but the first decision is now the SwiftUI surface rather than a store type.

## Default choices

| Need | Start with | Promote when |
|---|---|---|
| Stack plus sheet / cover | `@Router` + `RouterHost` | `FlowStore` + `FlowHost` for externally owned unified state |
| Modal-only feature | `@Router` + `RouterModalHost` | `ModalStore` + `ModalHost` for an externally owned queue |
| Split detail plus modal | `@Router` + `RouterSplitHost` | `NavigationSplitHost` for an externally owned stack-only detail authority |
| Native tabs | `@Router` + `@TabItem` + `RouterTabHost` | `TabCoordinatorView` for owned selection, a custom shell, or per-tab stores |
| One safe URL to one route | `@Router` allowlists + `@DeepLink` | Deep-link pipeline + Effects for authentication, pending replay, or multi-step plans |
| visionOS app scenes | `InnoRouterSpatial` + `@SceneRouter` + `@Scene` | `SceneStore` and manual hosts for direct event observation or custom composition |

## Decision tree

```text
Is this a visionOS window, volume, or immersive-space inventory?
├── Yes → @SceneRouter + @Scene, then install Route.scenes
└── No  → Is the feature a native tab shell?
         ├── Yes → @Router + @TabItem + RouterTabHost
         └── No  → Which local transition authority is needed?
                  ├── stack + modal → RouterHost
                  ├── modal only   → RouterModalHost
                  └── split detail → RouterSplitHost

Does another boundary need to own/restore/observe/mutate that state?
├── No  → keep the macro-first host
└── Yes → choose NavigationStore, ModalStore, FlowStore, or SceneStore

Does an incoming URL need authentication, deferral, replay, or multiple steps?
├── No  → @DeepLink on the route case; RouterHost / RouterSplitHost push it,
│         or RouterTabHost selects it
└── Yes → DeepLinkPipeline / FlowDeepLinkPipeline + InnoRouterEffects
```

`RouterModalHost` does not guess a presentation style for an incoming URL and
therefore does not install automatic deep-link handling. A modal-only URL
boundary must choose its style explicitly in `onOpenURL` or use the pipeline
and Effects path.

All ordinary route actions come from
`@EnvironmentRouter(Route.self)`. Spatial scene actions come from
`@EnvironmentSceneRouter(SceneRoute.self)`. A view should not receive a
host-owned store just to trigger a transition.

## Worked surfaces

### 1. Stack plus modal (`RouterHost`)

`RouterHost` owns one local `FlowStore`, so the same route type can be pushed
or presented without exposing the store.

```swift skip doc-fragment
@Router
enum LibraryRoute {
    case book(id: String)
    case settings

    var destination: some View {
        switch self {
        case .book(let id): BookDetailView(id: id)
        case .settings: SettingsView()
        }
    }
}

struct LibraryRoot: View {
    var body: some View {
        RouterHost(LibraryRoute.self) {
            LibraryView()
        }
    }
}

struct LibraryView: View {
    @EnvironmentRouter(LibraryRoute.self) private var router

    var body: some View {
        VStack {
            Button("Open book") { router.go(.book(id: "42")) }
            Button("Settings") { router.sheet(.settings) }
        }
    }
}
```

Use an externally owned `FlowStore` only when another boundary needs the
combined route timeline, restoration snapshot, middleware registry, or event
stream. A deliberately stack-only external authority uses `NavigationStore`
and `NavigationHost` instead.

### 2. Modal-only (`RouterModalHost`)

```swift skip doc-fragment
@Router
enum AccountModal {
    case profile
    case onboarding

    var destination: some View {
        switch self {
        case .profile: ProfileView()
        case .onboarding: OnboardingView()
        }
    }
}

RouterModalHost(AccountModal.self) {
    AccountView()
}
```

Descendants call `sheet`, `cover`, `dismiss`, or `dismissAll`. On platforms
without native `fullScreenCover`, cover requests intentionally render as a
sheet without treating that normal adaptation as a configuration error.

### 3. Split detail (`RouterSplitHost`)

```swift skip doc-fragment
RouterSplitHost(LibraryRoute.self) {
    LibrarySidebar()
} root: {
    ContentUnavailableView("Select a book", systemImage: "book")
}
```

The host owns the detail stack and modal authority. Sidebar selection, column
visibility, and compact adaptation stay app-owned. `RouterSplitHost` is
explicitly unavailable on watchOS; use `RouterHost` there.

### 4. Native tabs (`RouterTabHost`)

```swift skip doc-fragment
@Router
enum AppTab {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    case settings

    var destination: some View {
        switch self {
        case .home: HomeView()
        case .settings: SettingsView()
        }
    }
}

RouterTabHost(AppTab.self, initial: .home)
```

Every case must be parameterless and carry exactly one `@TabItem` once tab
metadata is used. Descendants select tabs and update badges through
`@EnvironmentRouter`. Choose `TabCoordinatorView` for a custom shell or
externally owned selection.

### 5. One-route deep links (`@DeepLink`)

```swift skip doc-fragment
@Router(
    deepLinkSchemes: ["myapp", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum AppRoute {
    @DeepLink("/products/:id")
    case product(id: String)

    @DeepLink("/settings")
    case settings

    var destination: some View {
        switch self {
        case .product(let id): ProductView(id: id)
        case .settings: SettingsView()
        }
    }
}

RouterHost(AppRoute.self) { HomeView() }
```

The allowlists fail closed. `RouterHost` and `RouterSplitHost` push a resolved
route; `RouterTabHost` selects a resolved tab. Use the explicit matcher,
pipeline, and Effects path when a URL needs authentication, pending replay,
custom admission, dynamic patterns, or more than one transition.

### 6. visionOS scenes (`@SceneRouter`)

```swift skip visionos-only
import InnoRouterSpatial

@SceneRouter
enum AppScene {
    @Scene(.window)
    case main

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main: MainView()
        case .theatre: TheatreView()
        }
    }
}

@main
struct ExampleApp: App {
    var body: some Scene { AppScene.scenes }
}
```

The first case is launch-preferred, while every live generated scene can become
the dispatcher. Closing the launch scene therefore does not prevent a surviving
scene from reopening it or another declaration. Views rendered from that tree
use `@EnvironmentSceneRouter` to call `open`, `dismissWindow`, and
`dismissImmersive`. Promote to manual `SceneStore` composition when the
generated private store cannot satisfy direct event observation or custom scene
ownership.

### 7. Atomic app-boundary flow (`FlowStore`)

An explicit store remains correct when one URL or restoration snapshot must
atomically rebuild a push prefix and a modal tail.

```swift skip doc-fragment
@Routable
enum AppRoute {
    case onboarding
    case privacyPolicy
}

let flow = FlowStore<AppRoute>()
flow.apply(FlowPlan(steps: [
    .push(.onboarding),
    .sheet(.privacyPolicy),
]))
```

This advanced path carries a single `[RouteStep<R>]` timeline and its
invariants. It is a useful ownership choice, not setup every feature should
repeat. See
[`Tutorial-FlowDeepLinkPipeline`](../Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/Tutorial-FlowDeepLinkPipeline.md)
for authenticated and pending deep-link composition.

## Anti-patterns

- **Creating a Store before choosing a surface.** Start from the locally owned
  host. Promote only when an external owner has a concrete responsibility.
- **Passing a host-owned Store through the view tree.** Read typed actions from
  the matching environment facade.
- **Calling a capability the nearest host does not own.** A modal-only host
  does not provide navigation, and a tab host does not provide stack actions.
  Missing capabilities follow `EnvironmentMissingPolicy` with an actionable
  diagnostic.
- **Using `@DeepLink` for session policy.** Route declarations can decode one
  safe route; authentication and pending replay belong at the application
  boundary.
- **Using `SceneStore` merely because the app runs on visionOS.** Ordinary
  in-window navigation still uses `RouterHost`. Add spatial routing only when
  the app owns multiple windows, volumes, or immersive spaces.
- **One route enum for unrelated authorities.** `RouterHost` deliberately
  unifies one feature's push and modal identity; independent features and app
  shells should still own focused route types.

## Cross-references

- [README — Choosing the right surface](../README.md#choosing-the-right-surface)
- [`Docs/IntentSelectionGuide.md`](IntentSelectionGuide.md) — choosing named
  actions versus explicit intent values
- [`Docs/design-macro-first-surfaces.md`](design-macro-first-surfaces.md) — the
  implemented 5.0 surface contract
