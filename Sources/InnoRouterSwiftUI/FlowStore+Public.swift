// MARK: - FlowStore+Public.swift
// InnoRouterSwiftUI - public dispatch surface for FlowStore
// (send / apply) layered over the internal mutation pipeline.
// Copyright © 2026 Inno Squad. All rights reserved.
//
// Extracted from FlowStore.swift in the 4.1.0 cleanup so the store
// core does not have to host the public entry points alongside the
// FlowMutationPlan dispatch logic. Both methods are thin wrappers
// that build a FlowMutationPlan via `mutationPlan(for:)` and route
// it through `apply(_:intent:)`.

import InnoRouterCore

extension FlowStore {

    /// Dispatches a high-level ``FlowIntent`` against the store.
    /// Builds the matching ``FlowMutationPlan`` for the current
    /// flow state and applies it through the unified inner-store
    /// commit path.
    public func send(_ intent: FlowIntent<R>) {
        if deferReentrantIntentIfNeeded(intent) {
            return
        }
        _ = InternalExecutionTrace.withSpan(
            domain: .flow,
            operation: "send",
            recorder: traceRecorder,
            metadata: ["intent": String(describing: intent)]
        ) {
            apply(mutationPlan(for: intent), intent: intent)
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    /// Applies a ``FlowPlan`` to the store, replacing the current
    /// path in one coordinated mutation. Equivalent to
    /// `send(.reset(plan.steps))` but communicates intent at the
    /// API boundary.
    ///
    /// This result-returning operation must complete synchronously. If it is
    /// called reentrantly from this FlowStore's observation callback, one of
    /// its inner-store observation callbacks, or a corresponding telemetry
    /// sink, it returns `.rejected(currentPath:)` without mutating state.
    /// Use `send(.reset(plan.steps))` when a reset must be scheduled from an
    /// observation callback; `send(_:)` defers that mutation until the current
    /// event sequence has finished delivery.
    @discardableResult
    public func apply(_ plan: FlowPlan<R>) -> FlowPlanApplyResult<R> {
        if let rejection = rejectReentrantApplyIfNeeded() {
            return rejection
        }
        return InternalExecutionTrace.withSpan(
            domain: .flow,
            operation: "applyPlan",
            recorder: traceRecorder,
            metadata: ["stepCount": String(plan.steps.count)]
        ) {
            let intent = FlowIntent<R>.reset(plan.steps)
            return apply(mutationPlan(for: intent), intent: intent)
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }
}
