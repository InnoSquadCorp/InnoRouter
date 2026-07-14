# Migrating from Nested Hosts to `FlowHost`

Replace manually composed `ModalHost { NavigationHost { ... } }`
surfaces with a single `FlowHost` backed by `FlowStore`. Preserve
existing `NavigationStore` / `ModalStore` configurations while
unlocking a serializable `[RouteStep<R>]` path and
`FlowStore.apply(_:)` for restoration + deep-link hydration.

This is an advanced promotion path. A self-contained push-only feature should
stay on `@Router` + `RouterHost`; introduce the externally owned stores below
only when push and modal state must be restored or deep-linked as one value.

## Starting point

An app that shipped before `FlowStore` landed typically has:

```swift skip doc-fragment
@main
struct LegacyApp: App {
    @State private var nav = NavigationStore<AppRoute>()
    @State private var modal = ModalStore<AppRoute>()

    var body: some Scene {
        WindowGroup {
            ModalHost(store: modal, destination: destination) {
                NavigationHost(store: nav, destination: destination) {
                    RootView()
                }
            }
        }
    }
}
```

Two stores. Two hosts. Path + modal state cannot be round-tripped
as one value — the app can't persist "user is 3 screens deep
inside a presented sheet" without hand-serializing both halves.

## Target shape

```swift skip doc-fragment
@main
struct MigratedApp: App {
    @State private var flow = FlowStore<AppRoute>()

    var body: some Scene {
        WindowGroup {
            FlowHost(
                store: flow,
                destination: destination,
                root: { RootView() }
            )
        }
    }
}
```

One store. One host. `flow.path: [RouteStep<AppRoute>]` is the
single source of truth; push + sheet + cover are three cases of
the same enum.

## Migration steps

### 1. Swap the host layering

Replace the nested host pair with `FlowHost`. `FlowHost` owns the
same `ModalHost` + `NavigationHost` composition internally —
external observable behavior is unchanged — but views now resolve
intents through a `FlowIntent` dispatcher in the SwiftUI
environment.

### 2. Route view intents through `FlowIntent`

Old:
```swift skip doc-fragment
navigationStore.send(.go(.detail))
modalStore.present(.sheet, style: .sheet)
```

New:
```swift skip doc-fragment
@EnvironmentFlowIntent(AppRoute.self) private var flow
// ...
flow(.push(.detail))
flow(.presentSheet(.sheet))
```

`FlowStore.send` still delegates to the inner
`NavigationStore.send` and `ModalStore.present`, so any middleware
or telemetry attached to those stores continues to run.

### 3. Port store configuration through `FlowStoreConfiguration`

`FlowStoreConfiguration` composes `NavigationStoreConfiguration` +
`ModalStoreConfiguration`, so existing configs port 1:1:

```swift skip doc-fragment
let flow = FlowStore<AppRoute>(
    configuration: .init(
        navigation: legacyNavigationConfiguration,
        modal: legacyModalConfiguration,
        onEvent: { event in
            switch event {
            case .pathChanged(let old, let new):
                Log.debug("flow path: \(old) -> \(new)")
            case .intentRejected(let intent, let reason):
                Log.info("flow rejected \(intent): \(reason)")
            case .navigation(let event):
                Log.debug("navigation event: \(event)")
            case .modal(let event):
                Log.debug("modal event: \(event)")
            }
        }
    )
)
```

In 5.0, each store configuration has one typed `onEvent` callback.
Remove the former per-case callback arguments and switch over the
matching event enum instead. The flow-level callback also receives
the inner navigation and modal events as wrapped cases; callbacks
already installed on the two legacy configurations still receive
their direct `NavigationEvent` / `ModalEvent` values.

### 4. Handle the two new invariant-violation paths

`FlowStore` rejects intents that would violate its invariants:

| Intent situation | Reason emitted |
|---|---|
| `.push` while a modal tail is active | `.pushBlockedByModalTail` |
| `.reset([.sheet, .push])` (modal not at tail) | `.invalidResetPath` |
| Any intent cancelled by middleware | `.middlewareRejected(debugName:)` |

Subscribe to `flow.events` or handle `.intentRejected` in the
configuration's `onEvent` closure. The legacy
stores never had this signal; before the migration, a push attempt
during a sheet presentation silently no-opped or tripped up the
app in subtle ways.

### 5. Adopt `apply(_:)` for deep links and restoration

`FlowPlan<R>.steps` is `[RouteStep<R>]`, so once your routes opt
into `Codable`:

```swift skip doc-fragment
extension AppRoute: Codable {}
```

`StatePersistence<AppRoute>` round-trips the whole flow state:

```swift skip doc-fragment
let persistence = StatePersistence<AppRoute>()

// On app background
try persistence.encode(FlowPlan(steps: flow.path)).write(to: url)

// On launch
if let data = try? Data(contentsOf: url) {
    flow.apply(try persistence.decode(data))
}
```

Deep-link resolvers can emit a `FlowPlan` directly and hand it to
`flow.apply(_:)` to hydrate a push + sheet terminal URL in one
atomic step.

### 6. Migrate tests incrementally

`ModalTestStore` / `NavigationTestStore` that targeted legacy
stores keep building (typealiases preserve source compatibility).
Re-home the highest-value scenarios onto `FlowTestStore` when you
get a chance — a single `FlowTestStore` subscription asserts both
navigation and modal emissions in the same FIFO queue, which
usually compresses a 40-line legacy test into 15 lines.

## Rollback story

The migration is per-flow. Any screen tree that still uses the
nested host pair continues to build. `FlowHost` lives alongside
`ModalHost` / `NavigationHost`; adopting one doesn't remove the
others. Incremental migration by flow (onboarding, settings,
checkout, ...) is supported.

## Next steps

- Read <doc:Tutorial-LoginOnboarding> to see a greenfield flow
  composed with `FlowHost` + `ChildCoordinator`.
- Read the `Tutorial-TestingFlows` guide in the
  `InnoRouterTesting` documentation catalog for the full host-less
  test harness story.
- See the **`send(_:)` vs `execute(_:)` — picking the right entry
  point** section of the README for guidance on choosing among
  `send`, `execute`, `executeBatch`, and `executeTransaction` once
  the flow is migrated.
