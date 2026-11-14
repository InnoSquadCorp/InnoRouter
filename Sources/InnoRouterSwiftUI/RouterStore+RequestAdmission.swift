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
            // The request a lane was reserved for takes that lane over.
            if let activeTransitionID, reservedLaneID != transitionID {
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

    /// Whether a plain request can run to its terminal outcome without
    /// suspending: nothing is in flight, and no policy or authorization exists
    /// that the asynchronous pipeline would have to await.
    ///
    /// A cancelled calling task is excluded as well. The deferred path starts
    /// a fresh unstructured task, so its request does not inherit the caller's
    /// cancellation; running inline would, and would reject the request.
    var canCommitImmediately: Bool {
        dispatchTiming == .immediateWhenIdle
            && activeTransitionID == nil
            && queuedRequests.isEmpty
            && queuedSystemRepairs.isEmpty
            && policies.isEmpty
            && authorization == nil
            && dispatchGate.isOpen
            && !Task.isCancelled
    }

    /// Starts fire-and-forget work on its own task and counts it until that
    /// task begins, so ``canCommitImmediately`` stays false while an earlier
    /// request is still on its way to admission.
    ///
    /// The count is released at the top of the task, in the same main-actor
    /// job that admits the request, so nothing can run between the two.
    func startDispatchTask<Output: Sendable>(
        _ work: @escaping @MainActor @Sendable () async -> Output
    ) -> Task<Output, Never> {
        dispatchGate.unstartedDispatches += 1
        return Task { @MainActor [weak self] in
            self?.dispatchGate.unstartedDispatches -= 1
            return await work()
        }
    }

    /// Commits a plain request before returning, or returns `nil` when the
    /// request has to take the asynchronous pipeline.
    ///
    /// This is the synchronous counterpart of ``perform(_:context:)`` for the
    /// case where that pipeline would never suspend. Input admission, request
    /// observation, lane ownership, and execution are the same steps in the
    /// same order.
    func performImmediately(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        executionPrecondition: RouterRequestPrecondition<R>?,
        executionPreparation: RouterRequestPreparationBuilder<R>? = nil
    ) -> RouterOutcome<R>? {
        guard canCommitImmediately else { return nil }
        let transitionID = runtimeDependencies.makeTransitionID()
        if let rejection = requestAdmissionRejection(
            for: action, context: context, presentationResumeAuthority: nil
        ) {
            return reject(transitionID, reason: rejection, context: context)
        }
        let replayLimitation = replayLimitationCode(
            action: action, semantics: .action, authorization: nil,
            lifetimeMutation: .reconcile,
            hasPrecondition: executionPrecondition != nil,
            hasPreparation: executionPreparation != nil
        )
        let executionPrecondition = requestExecutionPrecondition(
            action: action, authorization: nil, existing: executionPrecondition,
            systemRepairIdentity: nil, isResumed: false
        )
        observeRequest(
            id: transitionID,
            action: action,
            context: context,
            expectedRevision: expectedRevision,
            semantics: .action,
            replayLimitationCode: replayLimitation
        )
        beginExecution(transitionID, rootID: transitionID,
                       requestKey: context.requestKey, systemRepairIdentity: nil)
        dispatchGate.ignoresTaskCancellation = true
        defer { dispatchGate.ignoresTaskCancellation = false }
        return executeImmediately(
            action,
            context: context,
            expectedRevision: expectedRevision,
            transitionID: transitionID,
            executionPrecondition: executionPrecondition,
            executionPreparation: executionPreparation
        )
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
