# Building a Login Onboarding Flow

Compose push, sheet, and cover steps into a single serializable flow with
`FlowStore`, then let the signup `ChildCoordinator` expose its result directly
to the same app-defined flow owner.

## Scenario

The app launches on a welcome screen. Tapping *Continue* pushes a
pre-auth detail screen. Tapping *Create account* presents a signup
sheet. When the signup finishes (or is cancelled) the owning flow
resumes — either navigating to `.home(user)` or staying put.

Modeling this with raw `NavigationStore` + `ModalStore` means two
authority objects, two view-layer hosts, and hand-rolled
continuation plumbing to surface the sheet result back to the
owner. `FlowStore` + `ChildCoordinator` collapse this to a single
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
    @State private var onboarding = OnboardingCoordinator()

    var body: some Scene {
        WindowGroup {
            FlowHost(
                store: onboarding.flowStore,
                destination: destination,
                root: {
                    WelcomeRootView {
                        Task { await onboarding.startSignUpFlow() }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func destination(_ route: AppRoute) -> some View {
        switch route {
        case .preAuth:
            PreAuthDetailView()
        case .signup:
            if let signUp = onboarding.activeSignUp {
                SignUpView(coordinator: signUp)
            }
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
    let startSignUp: @MainActor () -> Void

    var body: some View {
        VStack {
            Button("Continue") {
                router.go(.preAuth)
            }
            Button("Create account") {
                startSignUp()
            }
        }
    }
}
```

Use `router.send(flow:)` only for flow-specific operations that do not have a
focused action, such as resetting a complete `RouteStep` path.

## Awaiting a signup sub-flow

The signup sheet opens its own child coordinator that owns the step progression
(email → password → confirmation). The app-defined onboarding owner keeps that
child in presentation state, presents it through the same `FlowStore`, then
`await`s the final `UserID` through `signUp.waitForResult()`:

```swift skip doc-fragment
@MainActor
final class SignUpCoordinator: ChildCoordinator {
    typealias Result = UserID

    var onFinish: (@MainActor @Sendable (UserID) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?

    // ...step state + methods omitted

    func userDidCreateAccount(_ userID: UserID) {
        onFinish?(userID)   // emits the result back to the owner
    }

    func userCancelled() {
        onCancel?()          // the owner sees nil
    }
}

@Observable
@MainActor
final class OnboardingCoordinator {
    let flowStore = FlowStore<AppRoute>()

    // The sheet content observes this app-owned placement state.
    var activeSignUp: SignUpCoordinator?

    func startSignUpFlow() async {
        guard activeSignUp == nil else { return }

        let signUp = SignUpCoordinator()
        activeSignUp = signUp
        defer { activeSignUp = nil }

        flowStore.send(.presentSheet(.signup))
        let result = await signUp.waitForResult()
        flowStore.send(.dismiss)

        if let userID = result {
            flowStore.send(.push(.home(userID)))
        }
    }
}
```

`activeSignUp` determines which child the `.signup` destination renders;
`flowStore` remains the sole push-and-modal authority. `waitForResult()` only
waits for a result and never presents the child. It installs the child's `onFinish` /
`onCancel` callbacks before its first suspension, so the child can emit a
result at any point after the asynchronous call begins without a `@MainActor`
re-entrancy deadlock. Cancelling the caller task that awaits `waitForResult()`
resolves it with `nil`, invokes `parentDidCancel()`, and runs the `defer` that
clears the app-owned placement state. See
[`Docs/design-child-coordinator-handoff.md`](../../../../Docs/design-child-coordinator-handoff.md)
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
