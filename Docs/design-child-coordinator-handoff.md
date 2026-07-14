# Child coordinator handoff — design memo

## Why this memo

The P1-1 work in `Docs/competitive-analysis-and-roadmap.md` flagged
"FlowStore ↔ Coordinator 핸드오프 설계 메모 선행" as a prerequisite.
This memo records the design choice that the P1-1 implementation
(`ChildCoordinator` + `Coordinator.push(child:)`) is built on, so the
scope stays narrow and future work has a stable baseline.

## Problem

Child coordinators — e.g. an onboarding flow launched from a signed-in
home coordinator — cannot currently report `finish(result)` or
`cancel()` back to their parent in a typed way. Apps end up wiring
closures by hand per call site, which is what FlowStacks and
TCACoordinators solve out of the box.

## Decision — **Coordinator-first**, not FlowStore-first

Child lifetime is orchestrated at the **Coordinator layer**, not the
store layer:

- A `FlowStore` remains the authority over `path: [RouteStep<R>]` for
  its own scope. It has no notion of parent/child.
- A `Coordinator` (parent) decides **when** to instantiate a child
  coordinator and **when** to pop / dismiss the child's view.
- The child signals completion through two `@MainActor` callbacks —
  `onFinish(Result)` and `onCancel()` — stored as `@Sendable`
  closures and assigned by the parent at `push(child:)` time.
- The parent awaits a `Task<Result?, Never>` and drives the follow-up
  navigation itself (pop, mark onboarding complete, rerun a query, …).

### Why not FlowStore-owns-children

1. `FlowStore` is a deliberately tight authority over one unified
   path (push + sheet + cover). Introducing nested store ownership
   would re-introduce the "one store per surface" fragmentation that
   FlowStack was designed to collapse.
2. Children are application concerns: "I want to collect an address
   and come back with the result" is a coordinator-level goal, not a
   stack-state invariant.
3. Keeping children out of store authority means this primitive adds
   **zero risk** to existing state-machine semantics, middleware
   discipline, or deep-link rehydration.

## Handoff rules

1. Parent creates the child coordinator instance (plain `init`, no
   magic container). Parent owns the strong reference until the
   returned `Task` resolves.
2. Parent calls `parent.push(child:)` which installs the `onFinish` /
   `onCancel` callbacks on the child and returns `Task<Result?, Never>`.
   Re-installing callbacks on the same child instance is unsupported
   and fails fast.
3. The child renders its own `CoordinatorHost` / `FlowHost` inside
   the parent's view tree — typically as a pushed route, or a modal
   step — using its own store. The parent is **not** responsible for
   building the child's view, only for granting it space in the tree.
4. When the child is done, it calls `onFinish(value)` (or
   `onCancel()`). The callback resumes the parent's Task once. A
   second call is a no-op (idempotency guard).
5. The parent's `await` returns. The parent is responsible for tearing
   down the child's view (e.g. `store.send(.back)`). The child is not
   aware of its placement in the parent's stack.

## Out of scope for P1-1

- ~~**Task cancellation propagation** (parent cancels → children cancel).
  Needs a cancellation contract on the child's store; tracked as P2+
  concurrency work.~~ **Addressed in P3-1.** `ChildCoordinator` now
  declares a `parentDidCancel()` protocol method (default no-op), and
  `push(child:)` wires `withTaskCancellationHandler` so the child is
  notified on the main actor when the parent `Task` is cancelled. The
  hook is directional — `parentDidCancel` is parent → child, while
  `onCancel` remains child → parent. Store-level cancellation (for
  example, cancelling in-flight network work owned by the child's
  store) stays in the app; the override point is `parentDidCancel`.
- **Modal-hosted children / multi-child orchestration**. The primitive
  is neutral on presentation style, but tidy APIs (`presentSheet(child:)`,
  `raceChildren`) are deferred until an app needs them.
- **Child store persistence** between parent teardown and child finish.
  Parent keeps the strong ref — if the parent disappears, the child
  disappears with it; no rehydration contract.
- **Modifying the existing `StepCoordinator` wizard type**. That type
  is a step-machine helper, not a coordinator tree, and completion
  remains app-owned. If a wizard needs Task-based completion, wrap it
  in a `ChildCoordinator` adapter at the app layer.

## Implementation sketch

```swift skip doc-fragment
@MainActor
public protocol ChildCoordinator: AnyObject {
    associatedtype Result: Sendable
    var onFinish: (@MainActor @Sendable (Result) -> Void)? { get set }
    var onCancel: (@MainActor @Sendable () -> Void)? { get set }
}

public extension Coordinator {
    @MainActor
    func push<Child: ChildCoordinator>(
        child: Child
    ) -> Task<Child.Result?, Never>
}
```

See `Sources/InnoRouterSwiftUI/ChildCoordinator.swift` and the
`ChildCoordinator Tests` suite for the landed surface.
