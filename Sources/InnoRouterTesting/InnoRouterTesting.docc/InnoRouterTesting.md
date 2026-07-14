# InnoRouterTesting

Host-less, Swift-Testing native assertion harness for InnoRouter's navigation, modal, and flow authorities.

## Overview

`InnoRouterTesting` ships three test stores that mirror the production stores' public API and transparently compose with each configuration's typed `onEvent` callback:

- `NavigationTestStore` — asserts `NavigationStore` events (push/pop/batch/transaction/middleware mutation/path mismatch).
- `ModalTestStore` — asserts `ModalStore` events (present/dismiss/queue/intercept/middleware mutation).
- `FlowTestStore` — asserts `FlowStore` intents end-to-end, including the inner navigation and modal emissions.

No `@testable import` is required. The harness itself avoids app-side access
to FlowStore internals; configure inner navigation / modal behavior through
`FlowStoreConfiguration`.

### Event queue model

Each test store owns a FIFO queue. Every time the underlying store emits an event, the corresponding value is appended. Tests consume events in order via `receive(...)` or its typed helpers (`receiveChange`, `receivePresented`, `receiveIntentRejected`, and so on). A strict-mode test store fails via Swift Testing `Issue.record` if any events are left unasserted at `finish()` or deinit.

```swift skip doc-fragment
import Testing
import InnoRouterTesting

@Test
@MainActor
func pushHomeLogsChangeEvent() {
    let store = NavigationTestStore<AppRoute>()
    store.send(.push(.home))
    store.receiveChange { old, new in
        old.path.isEmpty && new.path == [.home]
    }
    store.finish()
}
```

### Exhaustivity

The default mode is `TestExhaustivity.strict`: unasserted events at store deinit (or at an explicit `finish()`) are reported as test issues. `TestExhaustivity.off` preserves explicit assertions but silences the final pending-event check — useful when incrementally migrating large legacy suites.

`assertNoPendingEvents()` is a non-terminal checkpoint. If events are pending, it reports and consumes that snapshot so the same failure is not repeated at deinit; later operations continue to enqueue normally. `finish()` consumes the final snapshot and closes observation. The first event emitted after `finish()` is always an issue, even in `.off`, and later events are discarded to avoid failure storms.

> Note: Swift Testing currently attributes issues recorded inside an isolated `deinit` to an *unknown test*, so a deinit-time leftover-event failure can be hard to trace back to the test that owned the store. Await all work and end each test with an explicit `finish()`, as the examples on this page do. It runs the strict check with the caller's source location and disarms the deinit-time fallback.

### User `onEvent` callbacks are preserved

When you pass a production `NavigationStoreConfiguration`, `ModalStoreConfiguration`, or `FlowStoreConfiguration` into a test store, its `onEvent` callback still receives every matching enum case. The test store appends the same value after the user callback runs, so production middleware and analytics pipelines behave under test exactly as they would in the app. A flow callback receives `.navigation(...)` and `.modal(...)` wrappers in addition to `.pathChanged` and `.intentRejected`.

### End-to-end flow assertions

`FlowTestStore` wraps `FlowStoreConfiguration.onEvent`, whose unified surface already includes the inner `NavigationStore` and `ModalStore` emissions as `.navigation(...)` / `.modal(...)`, and appends those events to one test queue. This lets a test assert the complete chain triggered by one `FlowIntent` — for instance, that a sheet-blocking middleware prevents the inner navigation store from seeing any command:

```swift skip doc-fragment
let store = FlowTestStore<AppRoute>(
    configuration: FlowStoreConfiguration(
        modal: ModalStoreConfiguration(
            middlewares: [
                ModalMiddlewareRegistration(
                    middleware: BlockSheetMiddleware(),
                    debugName: "BlockSheet"
                )
            ]
        )
    )
)

store.send(.presentSheet(.onboarding))
store.receiveIntentRejected(
    intent: .presentSheet(.onboarding),
    reason: .middlewareRejected(debugName: "BlockSheet")
)
store.finish()
```

## Topics

### Tutorials

- <doc:Tutorial-TestingFlows>
