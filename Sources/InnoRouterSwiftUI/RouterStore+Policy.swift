// MARK: - RouterStore+Policy.swift
// InnoRouterSwiftUI - asynchronous transition policy preparation
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

enum RouterPolicyPreparation {
    case allowed
    case rejected(RouterRejectionReason)
    case deferred(RouterDeferredTransition)
}

private enum RouterPolicyOperationResult {
    case decision(RouterPolicyDecision)
    case rejected(RouterRejectionReason)
}

extension RouterStore {
    func prepare(
        for transition: RouterTransition<R>,
        bypassesPolicies: Bool,
        startingAt startingPolicyIndex: Int,
        requestSemantics: RouterRequestSemantics<R>,
        authorization: RouterRequestAuthorization<R>?,
        lifetimeMutation: RouterScopeLifetimeMutation,
        requestRootID: RouterTransitionID,
        presentationCompletionOwner: RouterPresentationCompletionOwner,
        executionPrecondition: RouterRequestPrecondition<R>?,
        deferredResumePreparation: RouterDeferredResumePreparationBuilder<R>?
    ) async -> RouterPolicyPreparation {
        guard !requestCancellationIsPending(transition.id) else {
            return .rejected(.cancelled)
        }
        guard !bypassesPolicies else { return .allowed }

        for index in policies.indices.dropFirst(startingPolicyIndex) {
            let policy = policies[index]
            guard !requestCancellationIsPending(transition.id) else {
                return .rejected(.cancelled)
            }
            let preparation = await prepare(policy, transition: transition)
            switch preparation {
            case .decision(let decision):
                emit(.policyPrepared(
                    transitionID: transition.id,
                    policy: policy.name,
                    decision: decision
                ))
                guard !requestCancellationIsPending(transition.id) else {
                    return .rejected(.cancelled)
                }
                guard revision == transition.initialRevision else {
                    return .rejected(.staleState(
                        expectedRevision: transition.initialRevision,
                        actualRevision: revision
                    ))
                }
                if let rejection = executionPrecondition?(state) {
                    return .rejected(rejection)
                }
                switch decision {
                case .allow:
                    continue
                case .reject(let message):
                    return .rejected(.policy(name: policy.name, message: message))
                case .deferRequest(let id):
                    return deferTransition(
                        transition,
                        id: id,
                        policy: policy,
                        policyIndex: index,
                        requestSemantics: requestSemantics,
                        authorization: authorization,
                        lifetimeMutation: lifetimeMutation,
                        requestRootID: requestRootID,
                        presentationCompletionOwner: presentationCompletionOwner,
                        executionPrecondition: executionPrecondition,
                        resumePreparation: deferredResumePreparation
                    )
                }
            case .rejected(let reason):
                return .rejected(reason)
            }
        }
        return .allowed
    }

    private func prepare(
        _ policy: RouterPolicy<R>,
        transition: RouterTransition<R>
    ) async -> RouterPolicyOperationResult {
        if let policyTimeout, policyTimeout <= .zero {
            return .rejected(.policyTimedOut(name: policy.name))
        }
        let reservation: RouterOperationRegistry.Reservation
        switch policyOperations.reserve() {
        case .success(let admitted):
            reservation = admitted
        case .failure(let capacity):
            return .rejected(.policyCapacityExceeded(limit: capacity.limit))
        }
        let race = RouterTimeoutRace<RouterPolicyDecision>()
        activePolicyRaces[transition.id] = race
        let result = await race.run(
            timeout: policyTimeout,
            sleep: runtimeDependencies.sleep,
            reservation: reservation
        ) {
            await policy.prepare(transition)
        }
        if activePolicyRaces[transition.id] === race {
            activePolicyRaces.removeValue(forKey: transition.id)
        }
        switch result {
        case .value(let decision):
            return .decision(decision)
        case .timedOut:
            return .rejected(.policyTimedOut(name: policy.name))
        case .cancelled:
            _ = requestCancellationIsPending(transition.id)
            return .rejected(.cancelled)
        }
    }

    private func deferTransition(
        _ transition: RouterTransition<R>,
        id: RouterDeferralID,
        policy: RouterPolicy<R>,
        policyIndex: Int,
        requestSemantics: RouterRequestSemantics<R>,
        authorization: RouterRequestAuthorization<R>?,
        lifetimeMutation: RouterScopeLifetimeMutation,
        requestRootID: RouterTransitionID,
        presentationCompletionOwner: RouterPresentationCompletionOwner,
        executionPrecondition: RouterRequestPrecondition<R>?,
        resumePreparation: RouterDeferredResumePreparationBuilder<R>?
    ) -> RouterPolicyPreparation {
        guard deferredRequests[id] == nil else {
            return .rejected(.deferralConflict(id))
        }
        let createdAt = runtimeDependencies.now()
        let expiresAt = deferralConfiguration.timeToLive.map {
            createdAt.addingTimeInterval(Self.timeInterval(for: $0))
        }
        let metadata = RouterDeferredTransition(
            id: id,
            transitionID: transition.id,
            policy: policy.name,
            initialRevision: transition.initialRevision,
            source: transition.context.source,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let nextPresentationOwner = RouterPresentationCompletionOwner.deferral(id, incarnation: UUID())
        let request = DeferredRouterRequest(
            rootID: requestRootID,
            action: transition.action,
            context: transition.context,
            presentationCompletionOwner: nextPresentationOwner,
            semantics: requestSemantics,
            authorization: authorization,
            lifetimeMutation: lifetimeMutation,
            initialRevision: transition.initialRevision,
            nextPolicyIndex: policies.index(after: policyIndex),
            executionPrecondition: executionPrecondition,
            resumePreparation: resumePreparation,
            metadata: metadata
        )
        if let rejection = registerDeferredRequest(request) {
            return .rejected(rejection)
        }
        continueDeferredPresentationCompletion(
            for: transition.action,
            owner: presentationCompletionOwner,
            nextOwner: nextPresentationOwner
        )
        return .deferred(metadata)
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }
}

public extension RouterStore {
    /// Starts the canonical async pipeline for fire-and-forget view actions.
    @discardableResult
    func dispatch(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) -> Task<RouterOutcome<R>, Never> {
        Task { @MainActor [weak self] in
            guard let self else {
                let state = try! RouterState<R>()
                return .rejected(
                    id: RouterTransitionID(),
                    state: state,
                    revision: 0,
                    reason: .cancelled
                )
            }
            return await self.perform(action, context: context)
        }
    }
}
