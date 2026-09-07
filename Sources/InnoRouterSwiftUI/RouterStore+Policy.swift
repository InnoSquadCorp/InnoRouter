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

enum RouterPolicyRaceResult {
    case decision(RouterPolicyDecision)
    case timedOut
    case cancelled
}

@MainActor
final class RouterPolicyTimeoutRace {
    private var continuation: CheckedContinuation<RouterPolicyRaceResult, Never>?
    private var policyTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        timeout: Duration?,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        operation: @escaping @MainActor @Sendable () async -> RouterPolicyDecision
    ) async -> RouterPolicyRaceResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    resolve(.cancelled)
                    return
                }
                policyTask = Task { @MainActor [weak self] in
                    let decision = await operation()
                    self?.resolve(.decision(decision))
                }
                if let timeout {
                    timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await sleep(timeout)
                        } catch {
                            return
                        }
                        self?.resolve(.timedOut)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(.cancelled)
            }
        }
    }

    func cancel() {
        resolve(.cancelled)
    }

    private func resolve(_ result: RouterPolicyRaceResult) {
        guard let continuation else { return }
        self.continuation = nil
        policyTask?.cancel()
        timeoutTask?.cancel()
        policyTask = nil
        timeoutTask = nil
        continuation.resume(returning: result)
    }
}

extension RouterStore {
    func prepare(
        for transition: RouterTransition<R>,
        bypassesPolicies: Bool,
        startingAt startingPolicyIndex: Int,
        requestSemantics: RouterRequestSemantics<R>,
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
                        executionPrecondition: executionPrecondition,
                        resumePreparation: deferredResumePreparation
                    )
                }
            case .timedOut:
                return .rejected(.policyTimedOut(name: policy.name))
            case .cancelled:
                _ = requestCancellationIsPending(transition.id)
                return .rejected(.cancelled)
            }
        }
        return .allowed
    }

    private func prepare(
        _ policy: RouterPolicy<R>,
        transition: RouterTransition<R>
    ) async -> RouterPolicyRaceResult {
        if let policyTimeout, policyTimeout <= .zero { return .timedOut }

        let race = RouterPolicyTimeoutRace()
        activePolicyRaces[transition.id] = race
        let result = await race.run(timeout: policyTimeout, sleep: runtimeDependencies.sleep) {
            await policy.prepare(transition)
        }
        if activePolicyRaces[transition.id] === race {
            activePolicyRaces.removeValue(forKey: transition.id)
        }
        return result
    }

    private func deferTransition(
        _ transition: RouterTransition<R>,
        id: RouterDeferralID,
        policy: RouterPolicy<R>,
        policyIndex: Int,
        requestSemantics: RouterRequestSemantics<R>,
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
        let request = DeferredRouterRequest(
            action: transition.action,
            context: transition.context,
            semantics: requestSemantics,
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
            transitionID: transition.id,
            context: transition.context,
            deferralID: id
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
