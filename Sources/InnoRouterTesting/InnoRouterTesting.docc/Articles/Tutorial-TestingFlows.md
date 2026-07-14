# Testing Flows End-to-End with `FlowTestStore`

Assert the complete chain triggered by a single `FlowIntent` —
navigation, modal, middleware cancellation, path reconciliation —
through a single FIFO receive queue, without mounting any SwiftUI
host.

## Setup

Add `InnoRouterTesting` to the test target only:

```swift skip doc-fragment
.testTarget(
    name: "AppTests",
    dependencies: [
        .product(name: "InnoRouter",        package: "InnoRouter"),
        .product(name: "InnoRouterTesting", package: "InnoRouter"),
    ]
)
```

Then import both modules alongside Swift Testing:

```swift skip doc-fragment
import Testing
import InnoRouter
import InnoRouterTesting
```

## The happy path

```swift skip doc-fragment
private enum AppRoute: Route {
    case welcome, preAuth, signup
}

@Test
@MainActor
func pushingPreAuthEmitsNavigationAndPathChange() {
    let store = FlowTestStore<AppRoute>()

    store.send(.push(.preAuth))

    store.receiveNavigation { event in
        if case .changed(_, let to) = event { return to.path == [.preAuth] }
        return false
    }
    store.receivePathChanged { old, new in
        old.isEmpty && new == [.push(.preAuth)]
    }
    store.finish()
}
```

`FlowTestStore` owns a real `FlowStore` and subscribes to every
observation surface it exposes (flow, inner navigation, inner
modal). Events land in one FIFO queue; `receive*` helpers dequeue
them in the order the production stores emit.

## Modal + cancellation

`FlowTestStore` surfaces cancellations as first-class events, so
tests can assert them precisely:

```swift skip doc-fragment
@MainActor
private func blockSheetMiddleware() -> AnyModalMiddleware<AppRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in
        if case .present(let p) = command, p.style == .sheet {
            return .cancel(.middleware(debugName: nil, command: command))
        }
        return .proceed(command)
    })
}

@Test
@MainActor
func sheetBlockingMiddlewareCancelsTheIntent() {
    let store = FlowTestStore<AppRoute>(
        configuration: .init(
            modal: .init(
                middlewares: [.init(middleware: blockSheetMiddleware(), debugName: "BlockSheet")]
            )
        )
    )

    store.send(.presentSheet(.signup))

    // The preview path never commits — only .intentRejected fires.
    store.receiveIntentRejected(
        intent: .presentSheet(.signup),
        reason: .middlewareRejected(debugName: "BlockSheet")
    )
    #expect(store.path.isEmpty)
    store.finish()
}
```

## Skipping and draining

`skipReceivedEvents()` discards everything currently queued
without asserting, which is useful when a test only cares about
events *after* a setup mutation:

```swift skip doc-fragment
store.send(.presentSheet(.signup)) // enqueues .modal + .pathChanged
store.skipReceivedEvents()         // we don't care about setup

store.send(.push(.preAuth))
store.receiveIntentRejected(intent: .push(.preAuth), reason: .pushBlockedByModalTail)
```

## Exhaustivity

Default is `TestExhaustivity.strict` — any unasserted event at
`finish()` (or at deinit of the test store) triggers a Swift
Testing `Issue.record`. This catches the common mistake of
"missed that the modal also fired a `.presented` after the
intended intent."

Opt out selectively:

```swift skip doc-fragment
let store = FlowTestStore<AppRoute>(exhaustivity: .off)
```

`.off` preserves per-call assertions; only the end-of-life drain
check is silenced. Useful when migrating a legacy test in stages.

Use `assertNoPendingEvents()` between test phases when you need a
non-terminal checkpoint. It reports and consumes the current pending
snapshot, but later operations continue to enqueue. After awaiting all
work, call `finish()` once: it closes observation, and the first event
emitted past that boundary is an issue in either exhaustivity mode.

## Direct state inspection

`FlowTestStore` exposes the projected `path` for occasional direct
assertions:

```swift skip doc-fragment
#expect(store.path == [.push(.preAuth)])
```

Prefer `receive*` for production assertions — they cover both
state and the emission order — but escape hatches are useful for
sanity checks. The inner `NavigationStore` / `ModalStore` behind a
`FlowStore` are SPI in 4.0; use public flow events and `path` unless
you are writing focused package-internal invariant tests.

## Testing middleware behaviour directly

The modal-blocking example above tests middleware *through* a flow
store. Sometimes you want to test the middleware itself — does it
correctly pass through, cancel, or rewrite commands for every input
shape? `NavigationTestStore` + `ModalTestStore` let you do that
without a FlowStore in the middle.

```swift skip doc-fragment
@MainActor
private final class RecordingMiddleware: NavigationMiddleware {
    typealias RouteType = AppRoute

    private(set) var seenCommands: [NavigationCommand<AppRoute>] = []

    func willExecute(
        _ command: NavigationCommand<AppRoute>,
        state: RouteStack<AppRoute>
    ) -> NavigationInterception<AppRoute> {
        seenCommands.append(command)
        if case .push(let route) = command, route == .signup {
            return .cancel(.middleware(debugName: "BlockSignup", command: command))
        }
        return .proceed(command)
    }

    func didExecute(
        _ command: NavigationCommand<AppRoute>,
        result: NavigationResult<AppRoute>,
        state: RouteStack<AppRoute>
    ) -> NavigationResult<AppRoute> {
        result
    }
}

@Test
@MainActor
func middlewareCancelsSignupButNotWelcome() {
    let middleware = RecordingMiddleware()
    let store = NavigationTestStore<AppRoute>(
        configuration: .init(
            middlewares: [.init(middleware: middleware, debugName: "Recorder")]
        )
    )

    store.send(.push(.welcome))
    store.receiveChange { _, to in to.path == [.welcome] }

    store.send(.push(.signup))
    store.receiveIntercepted(reason: .middleware(debugName: "BlockSignup", command: .push(.signup)))

    #expect(middleware.seenCommands.count == 2)
    store.finish()
}
```

Recording middlewares work naturally with `@MainActor final class`
and mutable state. Pair them with `receiveIntercepted` to assert
which interceptions fired and in what order, and with direct
reads on the middleware instance to assert which commands it saw.

## Property-based test recipes

InnoRouter's own property-based suites use
`Tests/InnoRouterTests/PropertyTestSupport.swift`. That helper lives
in this repository's test target, not in the shipped
`InnoRouterTesting` product, so downstream apps should copy or adapt
the pattern rather than expect `@testable import InnoRouterTesting`
to expose `SeededGenerator`, `Arbitrary`, or `FlowModelState`.

The idiom is **Swift Testing `@Test(arguments:)` iterated over many
seeds**, each seed driving a deterministic random intent stream:

```swift skip doc-fragment
@Test(arguments: 0..<100)
@MainActor
func randomFlowIntentsPreserveInvariants(seed: UInt64) async {
    var rng = SeededGenerator(seed: seed)
    let store = FlowTestStore<AppRoute>(exhaustivity: .off)

    for _ in 0..<30 {
        let intent = Arbitrary.flowIntent(
            rng: &rng,
            routes: [.welcome, .preAuth, .signup]
        )
        store.send(intent)
    }

    // Invariant: modal-tail is always the final step, never in the middle.
    let modalIndices = store.path.indices.filter { store.path[$0].isModal }
    #expect(modalIndices.allSatisfy { $0 == store.path.count - 1 })
}
```

Swift Testing runs the 100 parameterised cases in parallel by
default, so total wall-clock time stays close to a single iteration.

A pairs-with pattern: **run the random stream through both the
real store and a reference model**, then assert they agree step by
step. That's how `FlowStorePropertyBasedTests` catches subtle
divergences between the journal-driven implementation and the
intended semantics. See this repository's PropertyTestSupport source
for the model-driven `FlowModelState` pattern.

## Next steps

- Read the `Tutorial-LoginOnboarding` guide in the
  `InnoRouterSwiftUI` documentation catalog for the end-to-end flow
  being tested here.
- Read the `Tutorial-MiddlewareComposition` guide in the
  `InnoRouterSwiftUI` documentation catalog for the middleware
  surfaces the harness asserts against.
- Cross-reference `<doc:Rejection-Reasons>` (in InnoRouterCore) for
  the full rejection taxonomy your `receiveIntentRejected` /
  `receiveIntercepted` calls can pattern-match on.
