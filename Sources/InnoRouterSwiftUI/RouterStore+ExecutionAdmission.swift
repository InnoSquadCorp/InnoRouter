// MARK: - RouterStore+ExecutionAdmission.swift
// InnoRouterSwiftUI - synchronous request ownership admission
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

@MainActor
extension RouterStore {
    /// Reject exact replay claims when runtime semantics are absent from the
    /// portable request representation. Never persist an incarnation or grant.
    func replayLimitationCode(
        action: RouterAction<R>,
        semantics: RouterRequestSemantics<R>,
        authorization requestAuthorization: RouterRequestAuthorization<R>?,
        lifetimeMutation: RouterScopeLifetimeMutation,
        hasPrecondition: Bool,
        hasPreparation: Bool,
        resumeAuthority: RouterPresentationResumeAuthority? = nil
    ) -> String? {
        if hostDescriptor != nil { return "runtime.hostContract" }
        if hasPresentationResultAuthority(in: action) { return "presentation.runtimeResultAuthority" }
        if lifetimeMutation.replacesOwnership { return "runtime.ownershipReplacement" }
        if authorization != nil || requestAuthorization != nil { return "runtime.authorization" }
        switch semantics {
        case .action, .featureAction, .featurePlan:
            if let resumeAuthority { return resumeAuthority.replayLimitationCode }
            return hasPrecondition || hasPreparation ? "runtime.executionPrecondition" : nil
        case .historyNavigation:
            return resumeAuthority?.replayLimitationCode
        }
    }

    private func hasPresentationResultAuthority(in action: RouterAction<R>) -> Bool {
        switch deferredPresentationTarget(in: action) {
        case .present(let id): return presentationWaiters[id] != nil
        case .dismiss(let path):
            guard case .stack(let stack) = state.node(at: path), let family = stack.presentationFamily else { return false }
            if presentationWaiters[family.id] != nil { return true }
            guard case .navigation = family else { return false }
            let child = path.appendingPresentation(family.id)
            return presentationWaiters.values.contains { waiter in
                waiter.ownerPath.domain == child.domain && waiter.ownerPath.components.starts(with: child.components)
            }
        case nil: break
        }
        switch action {
        case .apply: return !presentationWaiters.isEmpty
        case .dismissWindow(let id): return presentationWaiters.values.contains { $0.ownerPath.domain == .window(id) }
        case .dismissImmersiveSpace:
            return presentationWaiters.values.contains { if case .immersiveSpace = $0.ownerPath.domain { return true }; return false }
        default: return false
        }
    }

    func admitExecution(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        transitionID: RouterTransitionID,
        executionPrecondition: RouterRequestPrecondition<R>?,
        executionPreparation: RouterRequestPreparationBuilder<R>?
    ) -> RouterExecutionAdmission<R> {
        if requestCancellationIsPending(transitionID) {
            return .terminal(reject(
                transitionID,
                reason: .cancelled,
                context: context,
                action: action
            ))
        }

        if let rejection = executionPrecondition?(state) {
            return .terminal(reject(
                transitionID, reason: rejection, context: context, action: action
            ))
        }

        let preparedAction: RouterAction<R>
        if let executionPreparation {
            switch executionPreparation(state) {
            case .action(let action):
                preparedAction = action
            case .rejected(let reason):
                return .terminal(reject(
                    transitionID,
                    reason: reason,
                    context: context,
                    action: action
                ))
            }
        } else {
            preparedAction = action
        }

        if requestCancellationIsPending(transitionID) {
            return .terminal(reject(
                transitionID,
                reason: .cancelled,
                context: context,
                action: preparedAction
            ))
        }
        if let rejection = executionPrecondition?(state) {
            return .terminal(reject(
                transitionID,
                reason: rejection,
                context: context,
                action: preparedAction
            ))
        }
        if requestCancellationIsPending(transitionID) {
            return .terminal(reject(
                transitionID,
                reason: .cancelled,
                context: context,
                action: preparedAction
            ))
        }
        if let expectedRevision, revision != expectedRevision {
            return .terminal(reject(
                transitionID,
                reason: .staleState(
                    expectedRevision: expectedRevision,
                    actualRevision: revision
                ),
                context: context,
                action: preparedAction
            ))
        }
        return .action(preparedAction)
    }
}
