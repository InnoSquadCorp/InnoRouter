# Reconciling Deep Links End-to-End

Match a URL, apply an authentication policy, and produce a
`NavigationPlan` that `NavigationStore.executeBatch` applies in one
observable step. Queue the deep link while the user is signed out,
replay it after sign-in, and surface cancellation reasons through
typed outcomes.

## Scenario

`myapp://app/order/42` should land the user on the order detail for
order 42, but only when they're signed in. If the link arrives
while signed out, the app must remember it, route through the
sign-in flow, and then replay it — without dropping the original
URL context.

This tutorial intentionally uses an externally owned `NavigationStore`: the
deep-link effect handler must apply plans outside the SwiftUI host. A local
push-only feature should start with `@Router` + `RouterHost` and promote to
this shape when URL handling or restoration needs the authority.

## Modeling the routes

```swift skip doc-fragment
// This host-independent excerpt uses plain Route conformance. Add @Router and
// a destination property when this same enum also owns SwiftUI rendering.
enum AppRoute: Route {
    case home
    case signIn
    case order(id: String)
}
```

## Wiring the pipeline

`DeepLinkPipeline` owns the validate-then-match-then-authorize flow. Pass the
matcher directly so matcher input-limit failures remain typed rejections:

```swift skip doc-fragment
import Synchronization

let authentication = Mutex(false)
let matcher = DeepLinkMatcher<AppRoute> {
    DeepLinkMapping("/home") { _ in .home }
    DeepLinkMapping("/signin") { _ in .signIn }
    DeepLinkMapping("/order/:id") { parameters in
        guard let id = parameters.firstValue(forName: "id") else { return nil }
        return .order(id: id)
    }
}

let policy = DeepLinkAuthenticationPolicy<AppRoute>.required(
    shouldRequireAuthentication: { route in
        if case .order = route { return true }
        return false
    },
    isAuthenticated: { authentication.withLock { $0 } }
)

let pipeline = DeepLinkPipeline(
    allowedSchemes: ["myapp"],
    allowedHosts: ["app"],
    matcher: matcher,
    authenticationPolicy: policy
)
```

## Handling a URL

The `DeepLinkEffectHandler` bridges the pipeline output into
`NavigationStore`:

```swift skip doc-fragment
let store = NavigationStore<AppRoute>()
let effectHandler = DeepLinkEffectHandler(
    navigator: AnyBatchNavigator(store),
    matcher: matcher,
    allowedSchemes: ["myapp"],
    allowedHosts: ["app"],
    authenticationPolicy: policy
)

func handle(_ url: URL) {
    switch effectHandler.handle(url) {
    case .executed:
        break // The validated NavigationPlan has already been applied.
    case .executionFailed(_, let batch):
        Log.warning("deep-link batch failed after \(batch.executedCommands.count) attempted commands")
    case .pending:
        _ = store.execute(.push(.signIn))
    case .applicationRejected(_, let failure):
        Log.warning("deep-link plan rejected: \(failure)")
    case .rejected(let reason):
        Log.warning("deep link rejected: \(reason)")
    case .unhandled(let url):
        Log.warning("deep link unhandled: \(url)")
    case .invalidURL, .missingDeepLinkURL, .noPendingDeepLink:
        break
    }
}
```

## Replaying after sign-in

Once the user signs in, the handler resumes any queued deep link:

```swift skip doc-fragment
func userDidSignIn() {
    authentication.withLock { $0 = true }
    _ = effectHandler.resumePendingDeepLink()
}
```

The handler consults the retained `PendingDeepLink`, re-evaluates
the authentication policy, and only commits the batch if the new
state now permits the original URL. Any stale pending link (one
the user cancelled or that no longer validates) is dropped.

## Observing the reconciliation

`NavigationStore.events` exposes the full sequence of batch +
path-mismatch events as a single stream, which is handy for
diagnostics dashboards:

```swift skip doc-fragment
Task {
    for await event in store.events {
        switch event {
        case .batchExecuted(let result):
            analytics.track("deep_link_applied", [
                "routes": result.stateAfter.path.map(String.init(describing:))
            ])
        case .pathMismatch(let event):
            analytics.track("deep_link_mismatch", [
                "policy": event.policy.rawValue,
                "old": event.oldPath.map(String.init(describing:)),
                "new": event.newPath.map(String.init(describing:))
            ])
        default:
            continue
        }
    }
}
```

## Testing the chain

`NavigationTestStore` (in `InnoRouterTesting`) asserts the batch +
side effects for each branch:

```swift skip doc-fragment
@Test
@MainActor
func signedOutDeepLinkDefersUntilSignIn() {
    let store = NavigationTestStore<AppRoute>()
    let handler = DeepLinkEffectHandler(
        navigator: AnyBatchNavigator(store.store),
        matcher: matcher,
        authenticationPolicy: policy
    )

    let result = handler.handle(URL(string: "myapp://app/order/42")!)

    #expect(result == .pending(handler.pendingDeepLink!))
    #expect(store.state.path.isEmpty)
    store.finish()
}
```

## Next steps

- Read <doc:Tutorial-LoginOnboarding> for how the sign-in flow that
  replays this deep link is modelled.
- Read <doc:Tutorial-MigratingFromNestedHosts> if the existing app
  still uses `ModalHost { NavigationHost { ... } }` pairs.
