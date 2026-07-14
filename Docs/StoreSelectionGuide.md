# Store Selection Guide

InnoRouter exposes four navigation authorities: `NavigationStore`,
`ModalStore`, `FlowStore`, and (experimentally) `SceneStore`. Picking
the right one is the most common adoption question. This guide
answers it with a decision tree and four worked examples.

The short rule: **start small, compose up**. Most apps need
`NavigationStore` + `ModalStore` and never need `FlowStore`.

## Decision tree

```text
Does this app surface need to push routes onto a stack?
├── No  → Does it need to present a sheet or full-screen cover?
│        ├── No  → You don't need an InnoRouter store. Use plain
│        │        SwiftUI views.
│        └── Yes → ModalStore + ModalHost
│
└── Yes → Does it also need sheet or cover presentation?
         ├── No  → NavigationStore + NavigationHost
         │        (or NavigationSplitHost on iPad / macOS for
         │         a sidebar+detail layout)
         │
         └── Yes → Do push and modal need to live in *one* state
                   that a single URL can rehydrate atomically, or
                   that you want to persist as one snapshot?
                   ├── No  → NavigationStore + NavigationHost
                   │         + ModalStore + ModalHost
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

`SceneStore` is the experimental visionOS spatial-scene authority.
It does not interact with the stack/modal axes above; treat it as a
parallel surface. See [`v2-principle-scorecard.md`](v2-principle-scorecard.md#experimental-surface)
for the stability statement.

## Four worked examples

### 1. Single push stack (`NavigationStore`)

A reading app with `Library → BookDetail → ChapterReader`. No
sheets, no covers, no split layout.

```swift skip doc-fragment
import SwiftUI
import InnoRouter
import InnoRouterMacros

@Routable
enum LibraryRoute {
    case library
    case book(id: String)
    case chapter(book: String, chapter: Int)
}

struct ReadingApp: View {
    @State private var store = try! NavigationStore<LibraryRoute>(
        initialPath: [.library]
    )

    var body: some View {
        NavigationHost(store: store) { route in
            switch route {
            case .library:           LibraryView()
            case .book(let id):      BookDetailView(id: id)
            case .chapter(let b, let c): ChapterReaderView(book: b, chapter: c)
            }
        } root: {
            LibraryView()
        }
    }
}
```

You only need `NavigationStore` here. Do not reach for `FlowStore`
just because the app might add a settings sheet later — adding
`ModalStore` independently is the additive minor change.

### 2. Push + independent modal (`NavigationStore` + `ModalStore`)

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
    @State private var navigation = try! NavigationStore<LibraryRoute>(
        initialPath: [.library]
    )
    @State private var modal = ModalStore<AppModalRoute>()

    var body: some View {
        ModalHost(store: modal) { route in
            switch route {
            case .settings:    SettingsView()
            case .onboarding:  OnboardingView()
            }
        } content: {
            NavigationHost(store: navigation) { route in
                // …same body as above…
            } root: {
                LibraryView()
            }
        }
    }
}
```

The two authorities stay independent. `NavigationIntent.go(.book(id:))`
does not touch the modal queue, and `ModalIntent.present(.settings)`
does not perturb the push stack. This is the most common shape and
should be your default once you outgrow `NavigationStore` alone.

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
user gesture — stay with `NavigationStore + ModalStore`.
`FlowStore` adds a single timeline invariant (one trailing modal,
modal always at the tail) that your app must honour. That is a
cost worth paying *only* when an URL or a persisted snapshot
needs to encode both pieces atomically.

The full deep-link case is documented in
[`Tutorial-FlowDeepLinkPipeline`](../Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/Tutorial-FlowDeepLinkPipeline.md).

### 4. iPad split + 3-column (`NavigationSplitHost`)

A reference app with a sidebar of categories, a middle list, and a
detail stack. The detail stack is the only thing InnoRouter owns;
sidebar selection and column visibility stay app-state.

```swift skip doc-fragment
@Routable
enum DetailRoute {
    case article(id: String)
    case section(id: String, anchor: String)
}

struct ReferenceApp: View {
    @State private var detail = try! NavigationStore<DetailRoute>(
        initialPath: []
    )
    @State private var sidebarSelection: Category? = .swift

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $sidebarSelection)
        } content: {
            CategoryList(category: sidebarSelection)
        } detail: {
            NavigationSplitHost(store: detail) { route in
                switch route {
                case .article(let id):
                    ArticleView(id: id)
                case .section(let id, let anchor):
                    SectionView(id: id, anchor: anchor)
                }
            }
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
  `NavigationStore + ModalStore`.
- **Reaching for a `Coordinator` before a store.** Coordinators are
  policy objects layered *over* stores. A view that just dispatches
  `NavigationIntent` does not need a coordinator — the
  `@EnvironmentNavigationIntent(Route.self)` property wrapper is
  enough.
- **Passing `NavigationStore` deep into the view tree.** Inject
  intent dispatchers via the environment instead. Hosts wire them
  for you.
- **One mega-`Route` enum across the entire app.** `Route` is
  per-authority. A reading app with a settings sheet has *two*
  small `enum`s — one for stack, one for modal — not one with 30
  cases.
- **Adopting `SceneStore` because the app runs on visionOS.** Most
  visionOS apps use a single `WindowGroup` and need only the same
  `NavigationStore + ModalStore` as iOS. Reach for `SceneStore`
  only when you actually open multiple windows / volumes /
  immersive spaces *and* want a single authority over their
  open/dismiss lifecycle. The surface is currently
  [experimental](v2-principle-scorecard.md#experimental-surface).

## Cross-references

- [README — Choosing the right surface](../README.md#choosing-the-right-surface)
- [`Docs/IntentSelectionGuide.md`](IntentSelectionGuide.md) — once a
  store is picked, this picks `NavigationIntent` vs `ModalIntent` vs
  `FlowIntent`.
- [`Docs/v2-principle-scorecard.md`](v2-principle-scorecard.md) —
  why each authority is separate.
