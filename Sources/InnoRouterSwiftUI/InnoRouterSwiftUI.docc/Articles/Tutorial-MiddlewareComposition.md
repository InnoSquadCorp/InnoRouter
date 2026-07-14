# Composing Middleware Across Navigation and Modal

Install logging, entitlement gating, and analytics middleware on
both `NavigationStore` and `ModalStore`. Inspect the participant
discipline that guarantees `didExecute` only runs for middlewares
that accepted the command.

## Scenario

Every `NavigationCommand` and `ModalCommand` should be logged
before it executes. A feature-flagged screen must be gated behind
an entitlement check. An analytics call must fire after the
command commits — but only for middlewares that actually
participated in the `willExecute` decision.

## Modeling routes

```swift skip doc-fragment
enum AppRoute: Route {
    case home
    case premiumDetail
    case paywall
}
```

## Logging middleware

Reuse the `AnyNavigationMiddleware` / `AnyModalMiddleware`
closure initializers so a minimal shared logger composes without
boilerplate:

```swift skip doc-fragment
@MainActor
func loggingNavigationMiddleware() -> AnyNavigationMiddleware<AppRoute> {
    AnyNavigationMiddleware(
        willExecute: { command, _ in
            Log.debug("navigation command: \(command)")
            return .proceed(command)
        },
        didExecute: { command, _, result in
            Log.debug("navigation committed: \(command) -> \(result)")
            return result
        }
    )
}

@MainActor
func loggingModalMiddleware() -> AnyModalMiddleware<AppRoute> {
    AnyModalMiddleware(
        willExecute: { command, _, _ in
            Log.debug("modal command: \(command)")
            return .proceed(command)
        },
        didExecute: { command, _, _ in
            Log.debug("modal committed: \(command)")
        }
    )
}
```

## Entitlement gating

The gate is itself a middleware; denying a command is just
returning `.cancel(reason)`:

```swift skip doc-fragment
@MainActor
func entitlementGateNavigation(hasPremium: @escaping @MainActor () -> Bool) -> AnyNavigationMiddleware<AppRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in
        guard case .push(.premiumDetail) = command, !hasPremium() else {
            return .proceed(command)
        }
        return .cancel(.middleware(debugName: "entitlement-gate", command: command))
    })
}
```

The cancellation surfaces through
`onCommandIntercepted(.cancelled(...))` on the store and through
`FlowRejectionReason.middlewareRejected(debugName: "entitlement-gate")`
when used from `FlowStore`.

## Wiring it all

```swift skip doc-fragment
let navStore = NavigationStore<AppRoute>(
    configuration: .init(
        middlewares: [
            .init(middleware: loggingNavigationMiddleware(), debugName: "logging"),
            .init(middleware: entitlementGateNavigation(hasPremium: { EntitlementStore.shared.hasPremium }), debugName: "entitlement-gate"),
        ]
    )
)

let modalStore = ModalStore<AppRoute>(
    configuration: .init(
        middlewares: [
            .init(middleware: loggingModalMiddleware(), debugName: "logging"),
        ]
    )
)
```

## Participant discipline

When a middleware cancels a command, only the middlewares that
already returned `.proceed` observe `didExecute`. The ones that
either didn't run yet (because a predecessor cancelled) or that
themselves cancelled are not consulted.

That guarantee is why the logger safely appears *before* the
entitlement gate — the logger's `didExecute` fires even if the
gate cancels, so the cancellation is still recorded. Reordering
to `[entitlement-gate, logging]` would skip the logger's
`didExecute` on cancellation.

## Observing a cancellation end-to-end

`ModalStore.events` surfaces `.commandIntercepted(.cancelled(...))`
and `NavigationStore.events` surfaces the same through
`.pathMismatch` (if the rewrite triggered a policy) plus the
direct cancellation. For a `FlowStore` in particular,
`FlowStore.events` wraps both in `.navigation(...)` / `.modal(...)`
cases so one subscriber sees the whole picture.

```swift skip doc-fragment
Task {
    for await event in flowStore.events {
        if case .modal(.commandIntercepted(_, .cancelled(let reason))) = event {
            Log.info("modal cancelled: \(reason)")
        }
        if case .intentRejected(_, .middlewareRejected(let name)) = event {
            Log.info("flow intent rejected by: \(name ?? "nil")")
        }
    }
}
```

## Testing middleware with FlowTestStore

`FlowTestStore` (in `InnoRouterTesting`) asserts the cancellation
chain without mounting SwiftUI:

```swift skip doc-fragment
@Test
@MainActor
func entitlementGateBlocksPremiumPush() {
    let store = FlowTestStore<AppRoute>(
        configuration: .init(
            navigation: .init(middlewares: [
                .init(middleware: entitlementGateNavigation(hasPremium: { false }), debugName: "gate")
            ])
        )
    )

    store.send(.push(.premiumDetail))

    store.receiveIntentRejected(
        intent: .push(.premiumDetail),
        reason: .middlewareRejected(debugName: "gate")
    )
    store.finish()
}
```

## Next steps

- Read <doc:Tutorial-LoginOnboarding> to see how middleware
  interacts with a multi-step flow plus a child coordinator.
- Read the `Tutorial-TestingFlows` guide in the
  `InnoRouterTesting` documentation catalog for the full host-less
  test harness tour.
