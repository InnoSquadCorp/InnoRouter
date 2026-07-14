# `StepCoordinator` vs `FlowStore`: Two Different Flows

Both types can participate in a multi-screen flow, but they answer
different questions. Reach for the right one — they are intentionally
*not* substitutable.

## The two questions

`FlowStore` answers: **"What is the current navigation+modal
state of this multi-screen feature?"** It owns a single array of
`RouteStep<R>` values, projected from an inner `NavigationStore`
plus `ModalStore`. Each step is either a push or a tail modal
(`.sheet` / `.cover`). The store delegates execution to the
inner authorities while keeping the projection consistent.

`StepCoordinator` answers: **"Which step of an ordered checklist
is the user on, and is that checklist complete?"** It tracks an
ordered `CaseIterable` enum (`Step`) and a
`completedSteps: Set<Step>`. Step transitions
(`next()`, `previous()`, `jump(to:)`) are pure local-state
mutations — `StepCoordinator` does not push or sheet anything by
itself.

## When to use which

| Scenario | Type | Why |
|---|---|---|
| Onboarding sign-up, KYC review, multi-page wizard | `StepCoordinator` | Ordered checklist state, no router authority |
| Checkout funnel that mixes push screens and a payment sheet | `FlowStore` | Single source of truth across nav + modal |
| Notification deep link that opens a push prefix and a modal | `FlowStore` | `FlowPlan` rehydration is the whole point of `FlowStore` |
| "Settings → Privacy → Account Deletion confirmation" flow | `FlowStore` | Modal at tail is naturally expressed as `.sheet(...)` step |
| Tab-bar progress indicator across a multi-tap form | `StepCoordinator` | `progress: Double` and `currentStep` are step-coordinator concerns |

## Composing them

`StepCoordinator` and `FlowStore` compose well — you can use a
`StepCoordinator` to drive *which step* a wizard is on, and a
`FlowStore` to drive *how that step's screens* render:

```swift skip doc-fragment
@Observable @MainActor
final class SignUpCoordinator: StepCoordinator {
    enum Step: CaseIterable, Hashable, Sendable {
        case email, password, kyc, profile
    }
    var currentStep: Step = .email
    var completedSteps: Set<Step> = []
    let flow = FlowStore<KycRoute>()  // rendering authority for .kyc step
}
```

Inside the view body, `currentStep` chooses *what* to render and
`flow` provides the navigation authority for the chosen step's
screens.

## 5.0 naming and ordering

InnoRouter 5.0 renamed `FlowCoordinator` to `StepCoordinator` so
the checklist helper is no longer confused with the navigation and
modal authority `FlowStore`. It also removed the separate `FlowStep`
and `index` requirements: progression follows `Step.allCases`.
Synthesized `CaseIterable` conformance uses declaration order; define
`allCases` manually when a different order is required. A manual order
must be non-empty, contain unique steps, and include the coordinator's
current step. Completion callbacks and result values remain app-owned
rather than protocol requirements because the transition helpers never
create a result.

## See also

- `FlowStore`
- `StepCoordinator`
- `FlowStoreConfiguration`
