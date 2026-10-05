// MARK: - RouterStore+RequestAdmission.swift
// InnoRouterSwiftUI - request input admission and execution scheduling
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterStore {
    package func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        bypassesPolicies: Bool,
        startingPolicyIndex: Int = 0,
        transitionID: RouterTransitionID? = nil,
        requestRootID: RouterTransitionID? = nil,
        requestSemantics: RouterRequestSemantics<R> = .action,
        authorization: RouterRequestAuthorization<R>? = nil,
        lifetimeMutation: RouterScopeLifetimeMutation = .reconcile,
        hostReplacement: RouterHostReplacement<R>? = nil,
        executionPrecondition: RouterRequestPrecondition<R>? = nil,
        executionPreparation: RouterRequestPreparationBuilder<R>? = nil,
        deferredResumePreparation: RouterDeferredResumePreparationBuilder<R>? = nil,
        systemRepairIdentity: RouterSystemRepairIdentity? = nil,
        presentationResumeAuthority: RouterPresentationResumeAuthority? = nil
    ) async -> RouterOutcome<R> {
        let transitionID = transitionID ?? runtimeDependencies.makeTransitionID()
        let requestRootID = requestRootID ?? transitionID
        if let rejection = requestAdmissionRejection(
            for: action, context: context, presentationResumeAuthority: presentationResumeAuthority
        ) {
            return reject(transitionID, reason: rejection, context: context)
        }
        let presentationCompletionOwner = presentationResumeAuthority?.owner ?? .transition(transitionID)
        // Resumes carry the original admission classification. Internal host,
        // lifetime, and authorization fences must not reclassify a portable
        // request, while original runtime limitations must never be erased.
        let replayLimitation = replayLimitationCode(
            action: action, semantics: requestSemantics, authorization: authorization,
            lifetimeMutation: lifetimeMutation,
            hasPrecondition: executionPrecondition != nil,
            hasPreparation: executionPreparation != nil || deferredResumePreparation != nil,
            resumeAuthority: presentationResumeAuthority
        )
        let executionPrecondition = requestExecutionPrecondition(
            action: action, authorization: authorization, existing: executionPrecondition,
            systemRepairIdentity: systemRepairIdentity, isResumed: presentationResumeAuthority != nil
        )
        observeRequest(
            id: transitionID,
            action: action,
            context: context,
            expectedRevision: expectedRevision,
            semantics: requestSemantics,
            replayLimitationCode: replayLimitation
        )

        return await withTaskCancellationHandler {
            if Task.isCancelled {
                observeCancellation(transitionID)
                return reject(
                    transitionID,
                    reason: .cancelled,
                    context: context,
                    action: action
                )
            }
            if let activeTransitionID {
                switch schedulingPolicy {
                case .rejectWhileBusy where !bypassesPolicies:
                    return reject(
                        transitionID,
                        reason: .busy(activeTransition: activeTransitionID),
                        context: context,
                        action: action
                    )
                case .rejectWhileBusy, .serialize:
                    return await withCheckedContinuation { continuation in
                        if requestCancellationIsPending(transitionID) {
                            cancelledRequestIDs.remove(transitionID)
                            continuation.resume(
                                returning: reject(
                                    transitionID,
                                    reason: .cancelled,
                                    context: context,
                                    action: action
                                )
                            )
                        } else {
                            enqueue(
                                QueuedRouterRequest(
                                    id: transitionID,
                                    rootID: requestRootID,
                                    action: action,
                                    context: context,
                                    presentationCompletionOwner: presentationCompletionOwner,
                                    semantics: requestSemantics,
                                    replayLimitationCode: replayLimitation,
                                    authorization: authorization,
                                    lifetimeMutation: lifetimeMutation,
                                    hostReplacement: hostReplacement,
                                    expectedRevision: expectedRevision,
                                    bypassesPolicies: bypassesPolicies,
                                    systemRepairIdentity: systemRepairIdentity,
                                    startingPolicyIndex: startingPolicyIndex,
                                    executionPrecondition: executionPrecondition,
                                    executionPreparation: executionPreparation,
                                    deferredResumePreparation: deferredResumePreparation,
                                    continuation: continuation
                                )
                            )
                        }
                    }
                }
            }

            beginExecution(transitionID, rootID: requestRootID,
                           requestKey: context.requestKey, systemRepairIdentity: systemRepairIdentity)
            return await execute(
                action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: bypassesPolicies,
                startingPolicyIndex: startingPolicyIndex,
                transitionID: transitionID,
                requestRootID: requestRootID,
                requestSemantics: requestSemantics,
                replayLimitationCode: replayLimitation,
                authorization: authorization,
                lifetimeMutation: lifetimeMutation,
                hostReplacement: hostReplacement,
                presentationCompletionOwner: presentationCompletionOwner,
                executionPrecondition: executionPrecondition,
                executionPreparation: executionPreparation,
                deferredResumePreparation: deferredResumePreparation
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(transitionID)
            }
        }
    }

    /// Validates request ownership and input before publishing or scheduling it.
    /// Rejections omit the action so inadmissible input is never described.
    private func requestAdmissionRejection(
        for action: RouterAction<R>,
        context: RouterTransitionContext,
        presentationResumeAuthority: RouterPresentationResumeAuthority?
    ) -> RouterRejectionReason? {
        if let authority = presentationResumeAuthority {
            guard authority.store == ObjectIdentifier(self), context.resumedDeferral == authority.id else {
                return .deferralConflict(authority.id)
            }
        }
        do {
            try resourceBudget.validateInput(action)
            return nil
        } catch {
            return .resourceLimit(error)
        }
    }
}
