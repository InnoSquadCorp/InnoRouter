# Child coordinator handoff — design memo

## Why this memo

The P1-1 work in `Docs/competitive-analysis-and-roadmap.md` flagged
"FlowStore ↔ Coordinator 핸드오프 설계 메모 선행" as a prerequisite.
This memo records the design choice that the P1-1 implementation
(`ChildCoordinator` + `ChildCoordinator.waitForResult()`) is built on, so the
scope stays narrow and future work has a stable baseline.

## Problem

Child coordinators — e.g. an onboarding flow launched from a signed-in
home feature — need to report `finish(result)` or `cancel()` back to
their owning feature in a typed way. Apps otherwise end up wiring
closures by hand per call site, which is what FlowStacks and
TCACoordinators solve out of the box.

## Decision — **child-owned result handoff**, app-owned placement

Result handoff belongs to the child, while presentation lifetime remains with
the app-defined owner:

- A `FlowStore` remains the authority over `path: [RouteStep<R>]` for
  its own scope. It has no notion of parent/child.
- An app-defined owner decides **when** to instantiate a child coordinator
  and **when** to pop or dismiss the child's view. That owner may be a
  `Coordinator`, a `FlowStore` owner, or another `@MainActor` feature model.
- The child signals completion through two `@MainActor` callbacks —
  `onFinish(Result)` and `onCancel()` — stored as `@Sendable`
  closures and installed by `waitForResult()`.
- The owner awaits the structured `child.waitForResult() async -> Result?`
  call and drives the follow-up navigation itself (pop, mark onboarding
  complete, rerun a query, …).

### Why not FlowStore-owns-children

1. `FlowStore` is a deliberately tight authority over one unified
   path (push + sheet + cover). Introducing nested store ownership
   would re-introduce the "one store per surface" fragmentation that
   FlowStack was designed to collapse.
2. Children are application concerns: "I want to collect an address
   and come back with the result" is an app-coordination goal, not a
   stack-state invariant.
3. Keeping children out of store authority means this primitive adds
   **zero risk** to existing state-machine semantics, middleware
   discipline, or deep-link rehydration.

## Handoff rules

1. The app-defined owner creates the child coordinator instance (plain
   `init`, no magic container) and stores it in presentation state while
   the child's route, sheet, or cover is visible. The `waitForResult()`
   call also keeps the instance alive until the handoff resolves, but it
   does not place the child's view in the hierarchy.
2. The owner awaits `child.waitForResult()`. The method installs the
   `onFinish` / `onCancel` callbacks before its first suspension and
   returns the typed result directly. Starting a second handoff on the
   same child while the first is still in progress is unsupported and
   fails fast; sequential reuse is allowed after callback cleanup.
3. The app renders the child inside its existing host tree — typically as a
   pushed route or modal step. `waitForResult()` does **not** build or present
   that view; it only waits for the terminal result.
4. When the child is done, it calls `onFinish(value)` (or
   `onCancel()`). The callback resumes the suspended `waitForResult()`
   call once. A second call is a no-op (idempotency guard).
5. The owner's `await` returns. The owner is responsible for tearing
   down the child's view (e.g. `store.send(.back)`). The child is not
   aware of its placement in the app's stack.

## Out of scope for P1-1

- ~~**Task cancellation propagation** (caller cancels → child is notified).
  Needs a cancellation contract on the child's store; tracked as P2+
  concurrency work.~~ **Addressed in P3-1.** `ChildCoordinator` now
  declares a `parentDidCancel()` protocol method (default no-op), and
  `waitForResult()` wires `withTaskCancellationHandler` so the child is
  notified on the main actor when the caller task awaiting the method
  is cancelled. The call then returns `nil`. The
  hook is directional — `parentDidCancel` is parent → child, while
  `onCancel` remains child → parent. Store-level cancellation (for
  example, cancelling in-flight network work owned by the child's
  store) stays in the app; the override point is `parentDidCancel`.
- **Modal-hosted children / multi-child orchestration**. The primitive
  is neutral on presentation style, but tidy APIs (`presentSheet(child:)`,
  `raceChildren`) are deferred until an app needs them.
- **Child store persistence** between owner teardown and child finish.
  App-owned presentation state keeps the strong reference needed by the
  view tree and clears it after the structured call finishes; there is no
  rehydration contract.
- **Modifying the existing `StepCoordinator` wizard type**. That type
  is a step-machine helper, not a coordinator tree, and completion
  remains app-owned. If a wizard needs async completion, wrap it
  in a `ChildCoordinator` adapter at the app layer.

## Implementation sketch

```swift skip doc-fragment
@MainActor
public protocol ChildCoordinator: AnyObject {
    associatedtype Result: Sendable
    var onFinish: (@MainActor @Sendable (Result) -> Void)? { get set }
    var onCancel: (@MainActor @Sendable () -> Void)? { get set }
    func parentDidCancel()
}

public extension ChildCoordinator {
    @MainActor
    func waitForResult() async -> Result?
}
```

See `Sources/InnoRouterSwiftUI/ChildCoordinator.swift` and the
`ChildCoordinator Tests` suite for the landed surface.
