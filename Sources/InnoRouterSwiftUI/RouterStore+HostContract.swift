import Foundation

import InnoRouterCore

/// One publication unit. Observers cannot read a graph from one commit and a
/// host descriptor from another commit, including synchronous willSet reads.
struct RouterCommittedValue<R: Route> {
    let state: RouterState<R>
    let hostDescriptor: RouterHostDescriptor<R>?
    let hostGeneration: UUID
    let revision: UInt64

    init(state: RouterState<R>, hostDescriptor: RouterHostDescriptor<R>?, hostGeneration: UUID = UUID(), revision: UInt64 = 0) {
        self.state = state
        self.hostDescriptor = hostDescriptor
        self.hostGeneration = hostGeneration
        self.revision = revision
    }
}

/// Runtime-only ownership, deliberately absent from Codable actions and plans.
package struct RouterHostReplacement<R: Route>: Sendable {
    let descriptor: RouterHostDescriptor<R>
}

@MainActor
public extension RouterStore {
    /// Replaces the complete graph and its frozen renderer contract together.
    ///
    /// The request uses ordinary authorization, policies, scheduling and
    /// deferrals. Rejection leaves both values intact. An accepted replacement
    /// increments revision and retires existing scope/presentation authority,
    /// even when persisted node IDs and state values are unchanged. Call this
    /// on the owning Store, not from a child scope or a SwiftUI body.
    func replaceHost(
        with plan: RouterPlan<R>,
        descriptor: RouterHostDescriptor<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        let id = reserveTransitionID()
        do {
            try descriptor.validate(plan.state, resourceBudget: resourceBudget)
        } catch {
            return reject(id, reason: .hostContract(error), context: context)
        }
        return await perform(
            .apply(plan), context: context, expectedRevision: nil, bypassesPolicies: false,
            transitionID: id, lifetimeMutation: .replaceAll,
            hostReplacement: .init(descriptor: descriptor)
        )
    }
}

@MainActor
extension RouterStore {
    /// Read-only native-host admission. Host construction never installs a new
    /// contract or implicitly reconciles an incompatible application graph.
    package func validateHostRenderer(
        shape: RouterHostShape, at path: RouterScopePath
    ) throws(RouterHostValidationFailure) {
        guard let hostDescriptor else {
            throw .init(code: .required, scope: path)
        }
        try hostDescriptor.validateRenderer(shape, at: path, in: state, resourceBudget: resourceBudget)
    }

    func requestExecutionPrecondition(
        action: RouterAction<R>, authorization: RouterRequestAuthorization<R>?,
        existing: RouterRequestPrecondition<R>?,
        systemRepairIdentity: RouterSystemRepairIdentity?, isResumed: Bool
    ) -> RouterRequestPrecondition<R>? {
        // Real resumes retain the original fence; repeated deferrals must not
        // accumulate another host-precondition closure on every continuation.
        let precondition = isResumed ? existing : hostGenerationPrecondition(existing: existing)
        if isRemovalOnlySystemRepair(action, identity: systemRepairIdentity) { return precondition }
        return authorizationPrecondition(request: authorization, existing: precondition, captureHostGeneration: false)
    }

    /// Capture before request observation/queueing; the same fence survives
    /// every policy suspension and a deferred resume, including rebase.
    func hostGenerationPrecondition(
        existing: RouterRequestPrecondition<R>?
    ) -> RouterRequestPrecondition<R> {
        let generation = committedValue.hostGeneration
        return { [weak self] state in
            if let rejection = existing?(state) { return rejection }
            guard self?.committedValue.hostGeneration == generation else {
                return .hostContract(.init(code: .stale, scope: .root))
            }
            return nil
        }
    }
}
