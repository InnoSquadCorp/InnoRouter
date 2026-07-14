# Migrating navigation from TCA to InnoRouter

This guide walks a TCA project through replacing its navigation
layer with InnoRouter while keeping the rest of the architecture
(reducers, effects, state) intact. InnoRouter is **not** a
replacement for TCA's reducer composition — it replaces the
parts of TCA that own *navigation state* and *modal authority*.

## Why this migration

TCA's navigation surface (`StackState<Element>`, `@Presents`,
`NavigationStackStore`) bundles three responsibilities:

1. **State authority** — what is on the stack, what modal is up.
2. **Action plumbing** — `Action.path(.push(...))`, `delegate`
   actions, `.dismiss` from the parent.
3. **View binding** — `NavigationStackStore` translates child
   stores into `NavigationLink`s.

InnoRouter takes ownership of (1) and (3) and replaces (2)
with a typed `NavigationIntent` enum that flows through the
SwiftUI environment. The reducer surface shrinks because the
parent reducer no longer needs to forward navigation actions
into `StackState` mutations.

## The minimal swap

A canonical TCA navigation feature looks like this:

```swift skip doc-fragment
@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var path = StackState<Path.State>()
    }

    enum Action {
        case path(StackActionOf<Path>)
    }

    @Reducer
    struct Path {
        enum State: Equatable { case detail(DetailFeature.State) }
        enum Action { case detail(DetailFeature.Action) }
        var body: some ReducerOf<Self> {
            Scope(state: \.detail, action: \.detail) { DetailFeature() }
        }
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in /* business logic */ }
            .forEach(\.path, action: \.path) { Path() }
    }
}

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        NavigationStackStore(store.scope(state: \.path, action: \.path)) {
            RootView(store: store)
        } destination: { store in
            switch store.state {
            case .detail:
                if let detail = store.scope(state: \.detail, action: \.detail) {
                    DetailView(store: detail)
                }
            }
        }
    }
}
```

After migration:

```swift skip doc-fragment
@Routable
enum AppRoute: Route {
    case detail(DetailFeature.State.ID)
}

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable { /* business state only */ }

    enum Action { /* business actions only */ }

    var body: some ReducerOf<Self> {
        Reduce { state, action in /* business logic */ }
    }
}

struct AppView: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var navigationStore = NavigationStore<AppRoute>()

    var body: some View {
        NavigationHost(store: navigationStore) {
            RootView(store: store)
        } destination: { route in
            switch route {
            case .detail(let id):
                DetailView(/* hydrate from id */)
            }
        }
    }
}
```

Three things changed:

1. The reducer's `path: StackState<Path.State>` is gone — the
   parent reducer no longer carries navigation state.
2. The parent action enum no longer routes
   `case path(StackActionOf<Path>)`.
3. The view uses `NavigationHost` + `NavigationStore<AppRoute>`
   in place of `NavigationStackStore` + `Path` reducer
   composition.

## Modal presentation (`@Presents` → `ModalStore`)

TCA's `@Presents` is conceptually equivalent to a `ModalStore`
slot. Replace:

```swift skip doc-fragment
@ObservableState
struct State {
    @Presents var sheet: SheetFeature.State?
}

enum Action {
    case sheet(PresentationAction<SheetFeature.Action>)
}

// View
.sheet(item: $store.scope(state: \.sheet, action: \.sheet)) { … }
```

with:

```swift skip doc-fragment
// State + Action no longer carry the modal slot.

// View
ModalHost(store: modalStore) { route in
    switch route { case .sheet: SheetView(…) }
}
```

The reducer no longer fires `Action.sheet(.presented(…))`; the
view dispatches `flowStore.send(.presentSheet(.sheet))` directly
through `@EnvironmentFlowIntent`.

## Stack + modal as one value (`StackState` + `@Presents` → `FlowStore`)

If a feature uses both navigation and modal authority, replace
both with a single `FlowStore<Route>` and observe `path:
[RouteStep<Route>]` as the single source of truth. The
`FlowPlan` value type makes the entire flow state Codable for
deep-link rehydration and state restoration.

## Testing — `TestStore` → `NavigationTestStore` / `FlowTestStore`

`InnoRouterTesting` ships host-less test stores that mirror
TCA's strict-exhaustivity ergonomics. Swap:

```swift skip doc-fragment
let testStore = TestStore(initialState: AppFeature.State()) { AppFeature() }
await testStore.send(.path(.push(id: 0, state: .detail(...))))
```

with:

```swift skip doc-fragment
let test = NavigationTestStore<AppRoute>()
test.execute(.push(.detail(id)))
test.expect(state: [.detail(id)])
```

The test store keeps the analytics / diagnostic `onEvent` callback the
production store wired through `NavigationStoreConfiguration`,
so the test asserts production telemetry without
`@testable import`.

## What stays in TCA

InnoRouter explicitly does **not** replace:

- Business logic reducers (`Reduce { state, action in … }`)
- Side effects (`Effect.send`, `Effect.run`)
- Dependency injection (`@Dependency`)
- Cross-feature coordination (parent ⇄ child reducer composition
  for non-navigation concerns)

A typical migrated codebase keeps every reducer in place; the
delta is the state slots and actions removed because navigation
no longer needs reducer-level modeling.

## Migration sequence

1. Start with a leaf feature whose navigation state lives only
   in the parent reducer's `StackState`. Replace its view-layer
   wiring with `NavigationHost` + `NavigationStore`.
2. Strip the matching `path` slot and `Path` reducer from the
   parent reducer. Verify the existing tests still pass against
   the trimmed reducer state.
3. Repeat per feature. The blast radius per migration is
   contained because each `NavigationStore` is independent.
4. Tackle modal authority feature-by-feature once the navigation
   stacks are ported. `@Presents` is the cheapest swap.
5. For features with both stack and modal authority, migrate
   them last by lifting the combined state into `FlowStore` and
   capturing the deep-link flow through `FlowPlan`.

## Common pitfalls

- **Action forwarding instinct.** TCA users habitually plumb
  navigation through actions even when the feature doesn't need
  it. With `@EnvironmentNavigationIntent`, the view dispatches
  intents directly; the reducer never sees a navigation action
  unless you explicitly want to gate one through middleware.
- **Strict concurrency floor.** InnoRouter requires iOS 18 /
  Swift 6.2. If the project still targets iOS 13–17, plan the
  platform bump as a separate PR before the navigation
  migration.
- **`@Bindable store` ergonomics.** `NavigationStore` is
  `@Observable` and works with `@Bindable` directly — no
  `bindable` modifier or scoped binding helpers are needed.

## Reference

- `NavigationStore` / `NavigationHost`
- `ModalStore` / `ModalHost`
- `FlowStore` / `FlowHost` / `FlowPlan`
- `InnoRouterTesting` (`NavigationTestStore`,
  `ModalTestStore`, `FlowTestStore`)
