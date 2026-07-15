# Building a Login Onboarding Flow

Compose push, sheet, and cover steps into a single serializable flow with `FlowStore`, then scope the signup sub-flow through a `ChildCoordinator` and await its result inline.

## Scenario

The app launches on a welcome screen. Tapping *Continue* pushes a
pre-auth detail screen. Tapping *Create account* presents a signup
sheet. When the signup finishes (or is cancelled) the parent flow
resumes — either navigating to `.home(user)` or staying put.

Modeling this with raw `NavigationStore` + `ModalStore` means two
authority objects, two view-layer hosts, and hand-rolled
continuation plumbing to surface the sheet result back to the
parent. `FlowStore` + `ChildCoordinator` collapse this to a single
store and one `await`.

This flow has crossed the macro-first local-stack boundary: push and modal
state must share one externally owned, serializable authority. A push-only
version should stay on `@Router` + `RouterHost` instead.

## Routes

```swift skip doc-fragment
enum AppRoute: Route {
    case preAuth
    case signup
    case home(UserID)
}
```

## Wiring the flow host

`FlowHost` renders environment-free navigation and modal surfaces around one
`FlowStore`, then publishes a unified router authority to its view subtree:

```swift skip doc-fragment
@main
struct DemoApp: App {
    @State private var flow = FlowStore<AppRoute>()

    var body: some Scene {
        WindowGroup {
            FlowHost(
                store: flow,
                destination: destination,
                root: { WelcomeRootView() }
            )
        }
    }

    @ViewBuilder
    private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .preAuth:
            PreAuthDetailView()
        case .signup:
            SignUpView()
        case .home(let id):
            HomeView(userID: id)
        }
    }
}
```

## Emitting intents from views

Views never mutate `FlowStore.path` directly. They read typed actions from
`@EnvironmentRouter`; the host projects those actions through `FlowStore`, so
middleware and event observation see every step:

```swift skip doc-fragment
struct WelcomeRootView: View {
    @EnvironmentRouter(AppRoute.self) private var router

    var body: some View {
        VStack {
            Button("Continue") {
                router.go(.preAuth)
            }
            Button("Create account") {
                router.sheet(.signup)
            }
        }
    }
}
```

Use `router.send(flow:)` only for flow-specific operations that do not have a
focused action, such as resetting a complete `RouteStep` path.

## Awaiting a signup sub-flow

The signup sheet opens its own `Coordinator` that owns the step
progression (email → password → confirmation). The outer
onboarding coordinator launches it via `push(child:)` and `await`s
the final `UserID`:

```swift skip doc-fragment
@MainActor
final class SignUpCoordinator: ChildCoordinator {
    typealias Result = UserID
    typealias RouteType = AppRoute

    // ...step state + methods omitted

    func userDidCreateAccount(_ userID: UserID) {
        onFinish(userID)   // emits the result back to the parent
    }

    func userCancelled() {
        onCancel()          // parent sees nil
    }
}

@MainActor
final class OnboardingCoordinator: Coordinator {
    typealias RouteType = AppRoute
    let navigationStore: NavigationStore<AppRoute>

    func startSignUpFlow() async {
        let result = await push(child: SignUpCoordinator())
        if let userID = result {
            navigationStore.send(.go(.home(userID)))
        }
    }
}
```

`push(child:)` installs the child's `onFinish` / `onCancel`
callbacks synchronously, so the child can emit a result at any
point — even before the parent's `await` suspends — without a
`@MainActor` re-entrancy deadlock. See
[`Docs/design-child-coordinator-handoff.md`](../../../../../Docs/design-child-coordinator-handoff.md)
for the design rationale.

## Verifying the flow host-lessly

`FlowTestStore` (in `InnoRouterTesting`) exercises the full chain
in a unit test without mounting any SwiftUI host:

```swift skip doc-fragment
@Test
@MainActor
func signUpCompletesOnboarding() {
    let store = FlowTestStore<AppRoute>()

    store.send(.presentSheet(.signup))
    store.receiveModal { if case .presented = $0 { return true }; return false }
    store.receiveModal { if case .commandIntercepted = $0 { return true }; return false }
    store.receivePathChanged()

    store.send(.dismiss)
    store.receiveModal { if case .dismissed = $0 { return true }; return false }
    store.receiveModal { if case .commandIntercepted = $0 { return true }; return false }
    store.receivePathChanged()
}
```

## Next steps

- Read <doc:Tutorial-MiddlewareComposition> to add analytics and
  authentication gating to the same flow.
- Read <doc:Tutorial-DeepLinkReconciliation> to extend the host so a
  push-notification URL can drop the user directly into `.home`
  state on launch.
