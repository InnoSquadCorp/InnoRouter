// MARK: - RouterStore+Deferral.swift
// InnoRouterSwiftUI - explicit continuation for policy-deferred requests
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

@MainActor
public extension RouterStore {
    /// Resolves one policy-deferred request without having occupied the
    /// serialized execution lane while the app awaited user or system input.
    func resolveDeferred(
        _ id: RouterDeferralID,
        with resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy = .requireUnchangedState
    ) async -> RouterOutcome<R> {
        await resolveDeferred(
            id,
            with: resolution,
            resumeStrategy: resumeStrategy,
            transitionID: nil
        )
    }

    package func resolveDeferred(
        _ id: RouterDeferralID,
        with resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy,
        transitionID requestedTransitionID: RouterTransitionID?
    ) async -> RouterOutcome<R> {
        let transitionID = requestedTransitionID ?? reserveTransitionID()
        guard let request = takeDeferredRequest(id) else {
            return reject(
                transitionID,
                reason: .deferralNotFound(id),
                context: .init()
            )
        }

        switch resolution {
        case .allow:
            var context = request.context
            context.resumedDeferral = id
            let executionPreparation: RouterRequestPreparationBuilder<R>? =
                if resumeStrategy == .rebaseOnCurrentState,
                   let resumePreparation = request.resumePreparation {
                    { currentState in
                        resumePreparation(currentState, resumeStrategy)
                    }
                } else {
                    nil
                }
            let presentationID: UUID? = switch deferredPresentationTarget(in: request.action) {
            case .present(let id): id
            case .dismiss, nil: nil
            }
            if let presentationID {
                registerPresentationRequest(presentationID, transitionID: transitionID)
            }
            let expectedRevision: UInt64? = switch resumeStrategy {
            case .requireUnchangedState: request.initialRevision
            case .rebaseOnCurrentState: nil
            }
            let outcome = await perform(
                request.action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: false,
                startingPolicyIndex: request.nextPolicyIndex,
                transitionID: transitionID,
                requestRootID: request.rootID,
                requestSemantics: request.semantics,
                executionPrecondition: request.executionPrecondition,
                executionPreparation: executionPreparation,
                deferredResumePreparation: request.resumePreparation
            )
            if let presentationID {
                unregisterPresentationRequest(presentationID, transitionID: transitionID)
            }
            if case .rejected(_, _, _, let reason) = outcome {
                finishDeferredPresentation(
                    for: request.action,
                    owner: .deferral(id),
                    reason: reason
                )
            }
            return outcome
        case .reject(let message):
            let reason = RouterRejectionReason.policy(
                name: request.metadata.policy,
                message: message
            )
            finishDeferredPresentation(
                for: request.action,
                owner: .deferral(id),
                reason: reason
            )
            var context = request.context
            context.resumedDeferral = id
            observeRequest(
                id: transitionID,
                action: request.action,
                context: context,
                semantics: request.semantics
            )
            return reject(
                transitionID,
                reason: reason,
                context: context,
                action: request.action
            )
        case .cancel:
            return cancelDeferredRequest(id, request: request, transitionID: transitionID)
        }
    }

    /// Allows one deferred request to continue through remaining policies.
    func resumeDeferred(
        _ id: RouterDeferralID,
        strategy: RouterDeferralResumeStrategy = .requireUnchangedState
    ) async -> RouterOutcome<R> {
        await resolveDeferred(id, with: .allow, resumeStrategy: strategy)
    }

    /// Cancels and removes one deferred request.
    func cancelDeferred(_ id: RouterDeferralID) async -> RouterOutcome<R> {
        cancelDeferredRequest(id)
    }
}

@MainActor
extension RouterStore {
    package func cancelDeferredRequest(
        _ id: RouterDeferralID
    ) -> RouterOutcome<R> {
        let transitionID = reserveTransitionID()
        guard let request = takeDeferredRequest(id) else {
            return reject(
                transitionID,
                reason: .deferralNotFound(id),
                context: .init()
            )
        }
        return cancelDeferredRequest(id, request: request, transitionID: transitionID)
    }

    private func cancelDeferredRequest(
        _ id: RouterDeferralID,
        request: DeferredRouterRequest<R>,
        transitionID: RouterTransitionID
    ) -> RouterOutcome<R> {
        finishDeferredPresentation(
            for: request.action,
            owner: .deferral(id),
            reason: .cancelled
        )
        var context = request.context
        context.resumedDeferral = id
        observeRequest(
            id: transitionID,
            action: request.action,
            context: context,
            semantics: request.semantics
        )
        return reject(
            transitionID,
            reason: .cancelled,
            context: context,
            action: request.action
        )
    }

    func registerDeferredRequest(
        _ request: DeferredRouterRequest<R>
    ) -> RouterRejectionReason? {
        if let timeToLive = deferralConfiguration.timeToLive,
           timeToLive <= .zero {
            return .deferralExpired(request.metadata.id)
        }
        let limit = deferralConfiguration.maximumPendingCount
        if deferredRequests.count >= limit {
            switch deferralConfiguration.overflowStrategy {
            case .rejectNewest:
                return .deferralCapacityExceeded(limit: limit)
            case .cancelOldest:
                guard let oldest = deferredTransitions.first,
                      let evicted = takeDeferredRequest(oldest.id) else {
                    return .deferralCapacityExceeded(limit: limit)
                }
                let reason = RouterRejectionReason.deferralEvicted(oldest.id)
                finishDeferredPresentation(
                    for: evicted.action,
                    owner: .deferral(oldest.id),
                    reason: reason
                )
                var context = evicted.context
                context.resumedDeferral = oldest.id
                _ = rejectRequest(
                    reason: reason,
                    context: context,
                    action: evicted.action
                )
            }
        }

        deferredRequests[request.metadata.id] = request
        deferredTransitions.append(request.metadata)
        scheduleExpiration(for: request)
        return nil
    }

    func takeDeferredRequest(
        _ id: RouterDeferralID
    ) -> DeferredRouterRequest<R>? {
        deferralExpirationTasks.removeValue(forKey: id)?.cancel()
        deferredTransitions.removeAll { $0.id == id }
        return deferredRequests.removeValue(forKey: id)
    }

    private func scheduleExpiration(for request: DeferredRouterRequest<R>) {
        guard let timeToLive = deferralConfiguration.timeToLive else { return }
        let id = request.metadata.id
        guard timeToLive > .zero else {
            expireDeferredRequest(id)
            return
        }
        let sleep = runtimeDependencies.sleep
        deferralExpirationTasks[id] = Task { @MainActor [weak self] in
            do {
                try await sleep(timeToLive)
            } catch {
                return
            }
            self?.expireDeferredRequest(id)
        }
    }

    private func expireDeferredRequest(_ id: RouterDeferralID) {
        guard let request = takeDeferredRequest(id) else { return }
        let reason = RouterRejectionReason.deferralExpired(id)
        finishDeferredPresentation(
            for: request.action,
            owner: .deferral(id),
            reason: reason
        )
        var context = request.context
        context.resumedDeferral = id
        _ = rejectRequest(
            reason: reason,
            context: context,
            action: request.action
        )
    }
}
