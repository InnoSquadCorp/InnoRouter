# Case study: shipping a 12-screen onboarding flow

A representative composition of `FlowStore`, `ChildCoordinator`,
`FlowPlan`, and `NavigationMiddleware` for a 12-screen
onboarding sequence with conditional branches, deep-link
resumption, and entitlement gating.

> This is a synthesized case study against the public InnoRouter
> surface (v5.0). It does not represent a specific shipped app
> but is structured to match the shape of recurring requests
> from teams evaluating the framework.

## The brief

The flow:

1. Launch screen.
2. Welcome + region picker.
3. Phone-number entry.
4. SMS verification (modal sheet).
5. Profile photo (skippable).
6. Display name.
7. Permission primer (one screen per permission requested).
8. Notification opt-in (system prompt, conditional next step).
9. Home location (skippable).
10. Work location (skippable).
11. Subscription pitch (modal sheet, conditional).
12. Welcome-home with feature tour.

Constraints:

- Auth state is owned by an existing `AuthClient`. The flow
  reads it but doesn't own it.
- Step ordering depends on user input (region → which
  permissions to request, region → subscription eligibility).
- The user can deep-link in via `inno://onboarding/profile` and
  resume mid-flow with prior steps already validated.
- Analytics fires on every step entry. A push from outside the
  flow (e.g. a referral landing) shouldn't double-fire entry
  events.

## The composition

```swift skip doc-fragment
@Routable
enum OnboardingRoute: Route, Codable {
    case launch
    case welcome
    case phoneNumber
    case profilePhoto
    case displayName
    case permissionPrimer(Permission)
    case homeLocation
    case workLocation
    case smsVerification(phoneNumber: String)
    case subscription(plan: SubscriptionPlan)
    case welcomeHome
}
```

One route type covers both push destinations and modal-only
destinations. `FlowStore<OnboardingRoute>` exposes `path:
[RouteStep<OnboardingRoute>]`: `.push(...)` steps drive the
navigation stack, while `.sheet(...)` and `.cover(...)` steps
drive modal presentation. Because the single route type is
`Codable`, the entire flow state is serializable to a
`FlowPlan`.

```swift skip doc-fragment
store.send(.presentSheet(.smsVerification(phoneNumber: phoneNumber)))

let rehydrationPlan: FlowPlan<OnboardingRoute> = .init(steps: [
    .push(.launch),
    .push(.welcome),
    .sheet(.subscription(plan: subscriptionPlan)),
])
```

## The driver

```swift skip doc-fragment
@MainActor
final class OnboardingDriver: ChildCoordinator {
    typealias Route = OnboardingRoute
    typealias Result = OnboardingResult

    let store: FlowStore<OnboardingRoute>
    private let auth: AuthClient
    private let analytics: AnalyticsClient

    init(auth: AuthClient, analytics: AnalyticsClient) {
        self.auth = auth
        self.analytics = analytics
        self.store = FlowStore(
            configuration: FlowStoreConfiguration(
                navigation: NavigationStoreConfiguration(
                    middlewares: [
                        .init(middleware: AnalyticsMiddleware(analytics: analytics),
                              debugName: "analytics"),
                        .init(middleware: EntitlementGate(auth: auth),
                              debugName: "entitlement"),
                    ]
                ),
                onEvent: { [analytics] event in
                    switch event {
                    case .pathChanged(_, let new):
                        analytics.record(.flowPathChanged(new))
                    case .intentRejected(_, let reason):
                        analytics.record(.flowRejected(reason))
                    case .navigation, .modal:
                        break
                    }
                },
                queueCoalescePolicy: .dropQueued
            )
        )
    }

    func start() {
        store.send(.replaceStack([.launch, .welcome]))
    }

    func handleDeepLink(_ url: URL) async {
        guard let plan = OnboardingDeepLink.plan(from: url, auth: auth) else {
            store.send(.push(.welcome))
            return
        }
        _ = store.apply(plan)
    }
}
```

`ChildCoordinator` returns an `OnboardingResult` to the parent
when the flow finishes:

```swift skip doc-fragment
enum OnboardingResult {
    case completed(profile: Profile)
    case abandoned(at: OnboardingRoute)
}
```

The parent calls
`parent.push(child: onboardingDriver) -> Task<OnboardingResult?>`
and `await`s the inline result, which threads cancellation back
through `parentDidCancel()` if the user pulls down on the
sheet shell.

## What the middlewares earn

`AnalyticsMiddleware` records `.willExecute` and `.didExecute`
events for every navigation command, deduplicated against the
`.pathChanged` case handled by `FlowStoreConfiguration.onEvent`.
Because middleware fires **before**
state mutates, the analytics event always carries the intended
target route, not the post-cancellation snapshot.

`EntitlementGate` reads `auth.isEligible(for: route)` for each
navigation prefix. If the user is not yet eligible for a
branch, navigation middleware cancels the `.replaceStack` /
`.reset` command with a typed reason; the flow falls back to
`.dropQueued` policy, dismissing any speculative modal state
that was queued behind the rejected navigation rewrite.
The `.intentRejected` case records a structured
`.middlewareRejected(debugName: "entitlement")` event so the
analytics layer can correlate with the same span ID.

## What `FlowPlan` earns

A deep link `inno://onboarding/profile` deserializes into:

```swift skip doc-fragment
let plan: FlowPlan<OnboardingRoute> = .init(
    steps: [
        .push(.launch),
        .push(.welcome),
        .push(.phoneNumber),
        .push(.profilePhoto),
    ]
)
```

`store.apply(plan)` is atomic: every step previews against
middleware in order, and the entire plan rolls back if any
preview rejects. The user never sees a half-applied flow even
if the entitlement gate decides one of the intermediate steps
is currently unreachable.

Because `OnboardingRoute` is `Codable`, the same `FlowPlan` can
be persisted to `UserDefaults` on `scenePhase: .background`
and restored on the next cold launch via
`FlowPlan(validating:)` — the validating constructor rejects
invariant violations (e.g. two modal steps) before the
authority sees them.

## What `InnoRouterTesting` earns

```swift skip doc-fragment
@Test
func onboardingResumesFromProfile() async throws {
    let auth = AuthClient.signedIn(region: .us)
    let analytics = RecordingAnalytics()
    let test = FlowTestStore<OnboardingRoute>(
        configuration: .init(
            navigation: .init(middlewares: [
                .init(middleware: EntitlementGate(auth: auth)),
            ])
        )
    )

    test.send(.push(.launch))
    test.expect(navigation: [.launch])
    try await test.apply(
        FlowPlan(steps: [
            .push(.launch),
            .push(.welcome),
            .push(.phoneNumber),
            .push(.profilePhoto),
        ])
    )
    test.expect(navigation: [.launch, .welcome, .phoneNumber, .profilePhoto])
    test.expect(modal: nil)
}
```

No SwiftUI host in scope. The exact same store configuration —
including production analytics middleware — is exercised in
the test and in production. `FlowTestStore` reuses the
`FlowStoreConfiguration.onEvent`, so the test can also verify
that `analytics.record(.flowPathChanged(...))` fired exactly
once per applied step.

## Observed wins

In a comparable TCA-modeled flow before the swap, the same
feature carried:

- ~340 lines of `Reducer` boilerplate for navigation actions
  alone (push / pop / present / dismiss / forward / hydrate).
- Three custom test harnesses to assert state restoration,
  deep-link replay, and entitlement gating in isolation.
- A bespoke "is the queue stale?" check after every cancelled
  command because TCA's `@Presents` carry-over isn't governed
  by a policy at the framework level.

The InnoRouter version drops the navigation reducer
boilerplate entirely (the framework owns the state machine),
folds the three test harnesses into one `FlowTestStore`
suite, and pushes the queue-coalesce decision into a single
`FlowStoreConfiguration` setting that participates in the
analytics middleware's span ID without extra wiring.

## When this composition is overkill

For a single-screen flow with no entitlement gating and no deep
link, drop straight to `NavigationStore<R>` + `NavigationHost`.
`FlowStore` earns its surface specifically when:

- Multiple steps need atomic deep-link rehydration.
- The modal authority is genuinely concurrent with the
  navigation stack (sheets, covers).
- A coordinator-level result (`OnboardingResult`) needs to
  bubble back to the parent.
- Middleware needs to gate or telemeter the entire flow.
