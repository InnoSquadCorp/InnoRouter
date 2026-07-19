// MARK: - FlowStore+Reentrancy.swift
// InnoRouterSwiftUI — FlowStore reentrant dispatch policy.

import InnoRouterCore

@MainActor
extension FlowStore {
    /// Defers only fire-and-forget `send(_:)` intents. Public `apply(_:)`
    /// returns the mutation result synchronously, so routing it through this
    /// queue would require fabricating a result before the plan executes.
    internal func deferReentrantIntentIfNeeded(_ intent: FlowIntent<R>) -> Bool {
        if reentrancy.isApplyingFlowMutation || reentrancy.isApplyingInternalMutation {
            reentrancy.enqueueReentrantIntent(intent)
            return true
        }

        switch reentrancy.innerObservationSource {
        case .navigation:
            navigationStore.performAfterObservationDelivery { [weak self] in
                self?.send(intent)
            }
            return true
        case .modal:
            modalStore.performAfterObservationDelivery { [weak self] in
                self?.send(intent)
            }
            return true
        case nil:
            break
        }

        guard reentrancy.isDispatchingFlowEvents else { return false }
        reentrancy.enqueueReentrantIntent(intent)
        return true
    }

    /// A result-returning `apply(_:)` cannot be deferred without claiming a
    /// mutation completed before it actually ran. Reject it while any Flow or
    /// inner-store observer is synchronously delivering an event; callers that
    /// need a reentrant reset can use `send(.reset(...))`, which is queued.
    internal func rejectReentrantApplyIfNeeded(
        _ plan: FlowPlan<R>
    ) -> FlowPlanApplyResult<R>? {
        guard reentrancy.isApplyingFlowMutation
            || reentrancy.isApplyingInternalMutation
            || reentrancy.isObservingInnerStore
            || reentrancy.isDispatchingFlowEvents
        else { return nil }

        emitRejectionDiagnostic(
            for: .reset(plan.steps),
            context: .init(
                origin: .reentrantApply,
                detail: "FlowStore.apply was invoked during synchronous event delivery."
            )
        )
        return .rejected(currentPath: path, reason: .reentrantApply)
    }

    internal func beginBufferingInnerEvents(from oldPath: [RouteStep<R>]) {
        reentrancy.beginBufferingFrame(from: oldPath)
    }

    internal func finishBufferingInnerEvents() {
        reentrancy.finishBufferingFrame()
    }

    internal func withInternalMutation<T>(_ body: () -> T) -> T {
        reentrancy.withInternalMutation(body)
    }

    internal func withFlowMutationBoundary<T>(_ body: () -> T) -> T {
        reentrancy.withFlowMutationBoundary(body)
    }
}
