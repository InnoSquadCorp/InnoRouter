# Rehydrating Composite Flows from a URL

Map a URL to a `FlowPlan` with push prefix and optional modal
terminal step, run it through authentication gating, and replay the
deferred link through `FlowDeepLinkEffectHandler` — all in one
atomic `FlowStore.apply(_:)`.

## Scenario

`myapp://app/home/detail/42` should land the user on the order detail
for order 42. `myapp://app/onboarding/privacy` should open a privacy
sheet over the current screen. Authenticated routes like
`myapp://app/secure` defer until sign-in completes, then replay.

Push-only pipelines (`DeepLinkPipeline` → `NavigationPlan<R>`) can't
express a URL that terminates on a modal. `FlowDeepLinkPipeline`
solves that by emitting `FlowPlan` — a single value holding both
the navigation prefix and the tail sheet/cover.

## Routes

```swift skip doc-fragment
enum AppRoute: Route {
    case home
    case detail(id: String)
    case comments(id: String)
    case privacyPolicy
    case secure
}
```

## Defining the matcher

`DeepLinkMapping` handlers return a **complete** `FlowPlan` so
multi-segment URLs expand atomically. The shared pattern syntax uses
`:parameter` for captures, terminal `*` wildcard,
path-only (host and scheme are filtered separately by the pipeline).
Non-terminal wildcards such as `/store/*/receipt` are invalid and
surface diagnostics instead of matching.

```swift skip doc-fragment
let matcher = DeepLinkMatcher<FlowPlan<AppRoute>> {
    DeepLinkMapping("/home") { _ in
        FlowPlan(steps: [.push(.home)])
    }
    DeepLinkMapping("/home/detail/:id") { params in
        guard let id = params.firstValue(forName: "id") else { return nil }
        return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
    }
    DeepLinkMapping("/home/detail/:id/comments/:cid") { params in
        guard let id = params.firstValue(forName: "id"),
              let cid = params.firstValue(forName: "cid") else { return nil }
        return FlowPlan(steps: [
            .push(.home),
            .push(.detail(id: id)),
            .push(.comments(id: cid))
        ])
    }
    DeepLinkMapping("/onboarding/privacy") { _ in
        FlowPlan(steps: [.sheet(.privacyPolicy)])
    }
    DeepLinkMapping("/secure") { _ in
        FlowPlan(steps: [.push(.secure)])
    }
}
```

## Wiring the pipeline

`FlowDeepLinkPipeline` composes scheme/host validation,
`DeepLinkAuthenticationPolicy` (reused from the push-only surface),
and the matcher:

```swift skip doc-fragment
let pipeline = FlowDeepLinkPipeline<AppRoute>(
    allowedSchemes: ["myapp"],
    allowedHosts: ["app"],
    matcher: matcher,
    authenticationPolicy: .required(
        shouldRequireAuthentication: { route in
            if case .secure = route { return true }
            return false
        },
        isAuthenticated: { SessionStore.shared.isAuthenticated }
    )
)
```

For unguarded apps pass `.notRequired` (the default) and skip the
policy closure entirely.

## Applying through FlowStore

`FlowDeepLinkEffectHandler` bridges the pipeline output into any
`FlowPlanApplier`. It also owns the pending slot, so keep the handler
in a stable owner rather than rebuilding it inside a SwiftUI body.
`FlowStore` already conforms:

```swift skip doc-fragment
import Foundation
import SwiftUI
import InnoRouter
import InnoRouterDeepLinkEffects

private final class SessionStore {
    static let shared = SessionStore()

    private let lock = NSLock()
    private var signedIn = false

    var isAuthenticated: Bool {
        lock.withLock { signedIn }
    }

    func markAuthenticated() {
        lock.withLock { signedIn = true }
    }
}

@MainActor
private final class DeepLinkCoordinator {
    let flow: FlowStore<AppRoute>
    let handler: FlowDeepLinkEffectHandler<AppRoute>
    private let session: SessionStore

    init(session: SessionStore = .shared) {
        self.session = session
        let flow = FlowStore<AppRoute>()
        self.flow = flow

        let matcher = DeepLinkMatcher<FlowPlan<AppRoute>> {
            DeepLinkMapping("/home") { _ in
                FlowPlan(steps: [.push(.home)])
            }
            DeepLinkMapping("/onboarding/privacy") { _ in
                FlowPlan(steps: [.sheet(.privacyPolicy)])
            }
            DeepLinkMapping("/secure") { _ in
                FlowPlan(steps: [.push(.secure)])
            }
        }
        let pipeline = FlowDeepLinkPipeline(
            allowedSchemes: ["myapp"],
            allowedHosts: ["app"],
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .secure = route { return true }
                    return false
                },
                isAuthenticated: { session.isAuthenticated }
            )
        )
        self.handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: flow
        )
    }

    func userDidSignIn() {
        session.markAuthenticated()
        _ = handler.resumePendingDeepLink()
    }
}

@main
struct DemoApp: App {
    @State private var coordinator = DeepLinkCoordinator()

    var body: some Scene {
        WindowGroup {
            FlowHost(
                store: coordinator.flow,
                destination: { route in
                    switch route {
                    case .home:
                        Text("Home")
                    case .detail(let id):
                        Text("Detail \(id)")
                    case .comments(let id):
                        Text("Comments \(id)")
                    case .privacyPolicy:
                        Text("Privacy")
                    case .secure:
                        Text("Secure")
                    }
                },
                root: { Text("Root") }
            )
            .onOpenURL { url in
                _ = coordinator.handler.handle(url)
            }
        }
    }
}
```

A single `handler.handle(url)` call:

1. Runs scheme/host validation.
2. Walks the matcher for a `FlowPlan`.
3. Runs the authentication policy across the plan until it finds the
   first protected route.
4. Either applies the plan through `flow.apply(_:)` or stores it as
   a `FlowPendingDeepLink`.

## Replaying after sign-in

Once the user signs in, resume the pending deep link:

```swift skip doc-fragment
func userDidSignIn() {
    coordinator.userDidSignIn()
}
```

The handler re-consults the authentication policy (now returning
`true`), drops the pending reference, and applies the plan atomically.
For an async gate (e.g. token refresh), use:

```swift skip doc-fragment
await coordinator.handler.resumePendingDeepLinkIfAllowed { pending in
    // Return true once the refresh has produced a live session.
    await AuthService.shared.refreshTokenIfNeeded()
}
```

The handler keeps a single pending slot:

- a newly deferred URL replaces the older pending link
- `clearPendingDeepLink()` drops the slot explicitly
- stale pending links (ones the user replaced by opening a different
  URL) are therefore dropped automatically

## Observing the chain

All three authorities surface on `FlowStore.events` as one
`AsyncStream`. A single subscriber sees the batch execution on the
navigation store, the modal presentation (if any), and the
settled FlowStore-level event as one chain. `FlowStore` wraps inner
navigation / modal events synchronously before emitting the
flow-level event, so one subscriber can assert the same ordering that
`FlowStoreConfiguration.onEvent` observes.

```swift skip doc-fragment
Task {
    for await event in flow.events {
        switch event {
        case .navigation(.batchExecuted(let result)):
            analytics.track("deep_link_applied", [
                "routes": result.stateAfter.path.map(String.init(describing:))
            ])
        case .modal(.presented(let presentation)):
            analytics.track("deep_link_opened_modal", [
                "route": String(describing: presentation.route)
            ])
        case .pathChanged(_, let new):
            analytics.track("flow_path", [
                "steps": new.map(String.init(describing:))
            ])
        default:
            continue
        }
    }
}
```

## Host-less testing

`FlowTestStore` wraps the same `flowStore.apply` path:

```swift skip doc-fragment
@Test
@MainActor
func multiSegmentURLRehydrates() {
    let store = FlowTestStore<AppRoute>()
    let handler = FlowDeepLinkEffectHandler(pipeline: pipeline, applier: store.store)

    _ = handler.handle(URL(string: "myapp://app/home/detail/42")!)

    store.receiveNavigation { event in
        if case .batchExecuted = event { return true }
        return false
    }
    store.receivePathChanged { _, new in
        new == [.push(.home), .push(.detail(id: "42"))]
    }
}
```

## Next steps

- See the push-only `Tutorial-DeepLinkReconciliation`
  walk-through in the `InnoRouterSwiftUI` catalog for apps that
  don't yet need modal-terminal URLs.
- Read the `Tutorial-LoginOnboarding` guide in the
  `InnoRouterSwiftUI` documentation catalog to see how the
  authenticated-replay loop fits a greenfield flow that uses
  `ChildCoordinator` for a sign-up sheet.
