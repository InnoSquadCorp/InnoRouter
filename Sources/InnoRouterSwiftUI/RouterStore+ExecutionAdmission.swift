// MARK: - RouterStore+ExecutionAdmission.swift
// InnoRouterSwiftUI - synchronous request ownership admission
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

@MainActor
extension RouterStore {
    /// Reject exact replay claims when runtime semantics are absent from the
    /// portable request representation. Never persist an incarnation or grant.
    func replayLimitationCode(
        semantics: RouterRequestSemantics<R>,
        authorization requestAuthorization: RouterRequestAuthorization<R>?,
        lifetimeMutation: RouterScopeLifetimeMutation,
        hasPrecondition: Bool,
        hasPreparation: Bool
    ) -> String? {
        if lifetimeMutation.replacesOwnership { return "runtime.ownershipReplacement" }
        if authorization != nil || requestAuthorization != nil { return "runtime.authorization" }
        switch semantics {
        case .action, .featureAction, .featurePlan:
            return hasPrecondition || hasPreparation ? "runtime.executionPrecondition" : nil
        case .historyNavigation:
            return nil
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
