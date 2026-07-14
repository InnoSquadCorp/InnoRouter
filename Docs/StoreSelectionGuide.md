# Store Selection Guide

InnoRouter exposes four navigation authorities: `NavigationStore`,
`ModalStore`, `FlowStore`, and `SceneStore`. Picking
the right one is the most common adoption question. This guide
answers it with a decision tree and four worked examples.

The short rule: **start small, compose up**. A self-contained push stack
starts with `@Router` + `RouterHost`; most apps only promote to an externally
owned `NavigationStore` when deep links, restoration, middleware, or
cross-surface composition need access to the authority.

## Decision tree

```text
Does this app surface need to push routes onto a stack?
├── No  → Does it need to present a sheet or full-screen cover?
│        ├── No  → You don't need an InnoRouter store. Use plain
│        │        SwiftUI views.
│        └── Yes → ModalStore + ModalHost
│
└── Yes → Does it also need sheet or cover presentation?
         ├── No  → @Router + RouterHost
         │        (promote to NavigationStore + NavigationHost when
         │         the store needs an external owner; use
         │         NavigationSplitHost for sidebar+detail layouts)
         │
         └── Yes → Do push and modal need to live in *one* state
                   that a single URL can rehydrate atomically, or
                   that you want to persist as one snapshot?
                   ├── No  → RouterHost + ModalStore + ModalHost
                   │         (two independent authorities, the
                   │          common case)
                   │
                   └── Yes → FlowStore + FlowHost
                             (single [RouteStep<R>] timeline,
                              atomic apply(_: FlowPlan), one
                              events stream)
```

`Coordinator` / `StepCoordinator` / `TabCoordinator` /
`ChildCoordinator` are not navigation authorities — they sit
*between* views and stores when you need policy routing or a
shell that owns a tab selection. Reach for them after you have
picked a store, not instead of one.

`SceneStore` is the visionOS spatial-scene authority. It lives in the
opt-in `InnoRouterSpatial` product rather than the default umbrella and does
not interact with the stack/modal axes above; treat it as a parallel surface.

## Four worked examples

### 1. Single push stack (`@Router` + `RouterHost`)

A reading app with `Library → BookDetail → ChapterReader`. No
sheets, no covers, no split layout.

```swift skip doc-fragment
import SwiftUI
import InnoRouter

@Router
enum LibraryRoute {
    case book(id: String)
    case chapter(book: String, chapter: Int)

    var destination: some View {
        switch self {
        case .book(let id):
            BookDetailView(id: id)
        case .chapter(let book, let chapter):
            ChapterReaderView(book: book, chapter: chapter)
        }
    }
}

struct ReadingApp: View {
    var body: some View {
        RouterHost(LibraryRoute.self) {
            LibraryView()
        }
    }
}
```

`RouterHost` creates and owns the `NavigationStore` locally, and `@Router`
supplies both `Route` conformance and destination rendering. The root view is
not a route in the pushed path, so the example does not duplicate `.library`
as its first destination.

Promote the store to the application boundary only when another subsystem
must reach it. Because `@Router` also supplies `DestinationRoute`, the advanced
host still does not need a destination switch:

```swift skip doc-fragment
@State private var store = NavigationStore<LibraryRoute>()

NavigationHost(store: store) {
    LibraryView()
}
```

Do not reach for `FlowStore` just because the app might add a settings sheet
later — adding `ModalStore` independently is the additive change.

### 2. Push + independent modal (`RouterHost` + `ModalStore`)

The same reading app gains a *Settings* sheet and an *Onboarding*
full-screen cover. Settings can open over any push depth, and the
cover is a one-shot first-launch flow.

```swift skip doc-fragment
@Routable
enum AppModalRoute {
    case settings
    case onboarding
}

struct ReadingApp: View {
    @State private var modal = ModalStore<AppModalRoute>()

    var body: some View {
        ModalHost(store: modal) { route in
            switch route {
            case .settings:    SettingsView()
            case .onboarding:  OnboardingView()
            }
        } content: {
            RouterHost(LibraryRoute.self) {
                LibraryView()
            }
        }
    }
}
```

The two authorities stay independent. `NavigationIntent.go(.book(id:))`
does not touch the modal queue, and `ModalIntent.present(.settings)`
does not perturb the push stack. This is the most common shape and
should be your default once you outgrow `RouterHost` alone.

### 3. Atomic URL → push prefix + modal tail (`FlowStore`)

`myapp://onboarding/privacy` must, in one observable transition,
rebuild a push prefix `[.onboarding]` *and* present a sheet
`.privacyPolicy` on top — and a state-restoration snapshot must
capture both pieces as one value. This is what `FlowStore` is for.

```swift skip doc-fragment
@Routable
enum AppRoute {
    case home
    case onboarding
    case privacyPolicy
}

let flow = FlowStore<AppRoute>()

flow.apply(FlowPlan(steps: [
    .push(.onboarding),
    .sheet(.privacyPolicy)
]))
```

If you do not need this atomic semantics — for example, the URL
only ever rebuilds the push stack and any modal step is a separate
user gesture — stay with `RouterHost + ModalStore`.
`FlowStore` adds a single timeline invariant (one trailing modal,
modal always at the tail) that your app must honour. That is a
cost worth paying *only* when an URL or a persisted snapshot
needs to encode both pieces atomically.

The full deep-link case is documented in
[`Tutorial-FlowDeepLinkPipeline`](../Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/Tutorial-FlowDeepLinkPipeline.md).

### 4. iPad sidebar + detail stack (`NavigationSplitHost`)

A reference app with a category sidebar and a detail stack rooted in the
category list. The detail stack is the only thing InnoRouter owns; sidebar
selection and column visibility stay app-state.

```swift skip doc-fragment
@Router
enum DetailRoute {
    case article(id: String)
    case section(id: String, anchor: String)

    var destination: some View {
        switch self {
        case .article(let id):
            ArticleView(id: id)
        case .section(let id, let anchor):
            SectionView(id: id, anchor: anchor)
        }
    }
}

struct ReferenceApp: View {
    @State private var detail = NavigationStore<DetailRoute>()
    @State private var sidebarSelection: Category? = .swift

    var body: some View {
        NavigationSplitHost(store: detail) {
            Sidebar(selection: $sidebarSelection)
        } destination: { route in
            route.destination
        } root: {
            CategoryList(category: sidebarSelection)
        }
    }
}
```

Do not push the sidebar `Category` into `NavigationStore`. Routing
authority is for *the part of the screen that pushes routes* — the
detail column. Keeping shell state app-owned is an explicit
principle (`Docs/v2-principle-scorecard.md` § Remaining trade-offs).

## Anti-patterns

- **`FlowStore` for every screen.** If push and modal flow
  independently, the FlowStore invariants (single trailing modal,
  one timeline) are friction without a payoff. Use
  `RouterHost + ModalStore`.
- **Reaching for a `Coordinator` before a store.** Coordinators are
  policy objects layered *over* stores. A view that just pushes and pops a
  typed route does not need a coordinator — `@EnvironmentRouter(Route.self)`
  is enough. Use `@EnvironmentNavigationIntent` only when the view genuinely
  needs to construct the lower-level intent value itself.
- **Passing `NavigationStore` deep into the view tree.** Inject
  intent dispatchers via the environment instead. Hosts wire them
  for you.
- **One mega-`Route` enum across the entire app.** `Route` is
  per-authority. A reading app with a settings sheet has *two*
  small `enum`s — one for stack, one for modal — not one with 30
  cases.
- **Adopting `SceneStore` because the app runs on visionOS.** Most
  visionOS apps use a single `WindowGroup` and need only the same
  `RouterHost + ModalStore` as iOS. Reach for `SceneStore`
  only when you actually open multiple windows / volumes /
  immersive spaces *and* want a single authority over their
  open/dismiss lifecycle. Add and import `InnoRouterSpatial` only in
  the targets that own those scene declarations.

## Cross-references

- [README — Choosing the right surface](../README.md#choosing-the-right-surface)
- [`Docs/IntentSelectionGuide.md`](IntentSelectionGuide.md) — once a
  store is picked, this picks `NavigationIntent` vs `ModalIntent` vs
  `FlowIntent`.
- [`Docs/v2-principle-scorecard.md`](v2-principle-scorecard.md) —
  why each authority is separate.
