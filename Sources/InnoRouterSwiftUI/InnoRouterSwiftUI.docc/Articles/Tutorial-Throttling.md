# Throttling Rapid Navigation Taps

Rate-limit navigation commands without threading timestamps through
every call site. `ThrottleNavigationMiddleware` cancels commands that
arrive within a minimum interval of a previously accepted command
sharing the same key.

## Scenario

Users double-tap a "Buy" button. The first tap pushes the purchase
screen; the second should be silently dropped. Rolling that logic
into every button is noise — middleware is the right layer.

## Installation

```swift skip doc-fragment
let store = NavigationStore<AppRoute>(
    configuration: NavigationStoreConfiguration(
        middlewares: [
            .init(
                middleware: AnyNavigationMiddleware(
                    ThrottleNavigationMiddleware<AppRoute>(
                        interval: .milliseconds(300)
                    )
                ),
                debugName: "throttle"
            )
        ]
    )
)
```

The default initializer uses `ContinuousClock` and groups all
commands under a single global window. Within 300 ms of a previous
successfully executed command, the next one is cancelled. If the
middleware is registered with `debugName: "throttle"`, the surfaced
reason becomes `.cancelled(.middleware(debugName: "throttle", command: …))`.

## Per-command keys

Group throttle windows by the command's identity or shape:

```swift skip doc-fragment
AnyNavigationMiddleware(
    ThrottleNavigationMiddleware<AppRoute>(interval: .milliseconds(300)) { command in
        if case .push(let route) = command {
            return "push-\(route)"   // each push route gets its own window
        }
        return nil                    // other commands pass through
    }
)
```

Return `nil` to opt a command out of throttling entirely.

## Testing with an injected clock

The middleware is generic over `Clock`, so tests can drive time
deterministically:

```swift skip doc-fragment
let clock = TestClock()
let throttle = ThrottleNavigationMiddleware<AppRoute, TestClock>(
    interval: .milliseconds(300),
    clock: clock,
    key: { _ in "all" }
)
store.addMiddleware(AnyNavigationMiddleware(throttle), debugName: "throttle")

store.send(.go(.home))
clock.advance(by: .milliseconds(50))
store.send(.go(.detail))         // cancelled — within window

clock.advance(by: .milliseconds(400))
store.send(.go(.settings))       // accepted — beyond window
```

## Composing with `.whenCancelled`

A throttle cancel surfaces as `.cancelled`, so
`.whenCancelled(primary, fallback:)` treats a throttled command the
same as any other cancelled command:

```swift skip doc-fragment
store.execute(
    .whenCancelled(
        .push(.detail),
        fallback: .push(.home)
    )
)
```

If the throttle middleware cancels the `.push(.detail)`, the
fallback `.push(.home)` is attempted next. `NavigationStore`
routes that fallback back through the full middleware chain, so a
global throttle key can cancel the fallback too if it still lands
inside the same throttle window. Each leg runs behind an internal
savepoint: if the fallback also fails or is cancelled, neither leg's
partial state is committed.

## Debounce?

Debounce semantics — "wait N ms, then fire the latest" — live in
`DebouncingNavigator`, not in `NavigationCommand`. That keeps the
engine synchronous while the async wrapper owns the timer,
cancellation, and `Clock` injection needed for deterministic tests.
Use throttle middleware for synchronous "reject too soon" behavior
and `DebouncingNavigator` for delayed "latest wins" behavior.

## Next steps

- See <doc:NavigationStore-and-Hosts> for the typed `onEvent` callback and
  `NavigationStore.events` stream that expose throttle cancellations.
- See <doc:Tutorial-MiddlewareComposition> for the broader
  middleware composition story (logging, entitlement gating,
  analytics).
