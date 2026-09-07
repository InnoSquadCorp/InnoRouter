// MARK: - RouterStore+Scheduling.swift
// InnoRouterSwiftUI - request queue ownership and coalescing
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

@MainActor
extension RouterStore {
    func cancelRequest(_ id: RouterTransitionID) {
        if activeTransitionID == id {
            if cancelledRequestIDs.insert(id).inserted {
                observeCancellation(id)
            }
            activePolicyRaces[id]?.cancel()
            activeQueuedExecutionTask?.cancel()
            return
        }
        guard let index = queuedRequests.firstIndex(where: { $0.id == id }) else {
            return
        }
        observeCancellation(id)
        let request = queuedRequests.remove(at: index)
        cancelledRequestIDs.remove(id)
        request.continuation.resume(
            returning: reject(
                id,
                reason: .cancelled,
                context: request.context,
                action: request.action
            )
        )
        resumeRequestCompletionWaiters(for: id)
    }

    /// Consumes cancellation from the currently executing Task at synchronous
    /// pipeline boundaries and records its provenance before terminal emission.
    /// Explicit Store cancellation has already inserted the request ID and is
    /// therefore not emitted twice.
    func requestCancellationIsPending(_ id: RouterTransitionID) -> Bool {
        if Task.isCancelled,
           cancelledRequestIDs.insert(id).inserted {
            observeCancellation(id)
        }
        return Task.isCancelled || cancelledRequestIDs.contains(id)
    }

    func enqueue(_ request: QueuedRouterRequest<R>) {
        guard let key = request.context.requestKey else {
            appendPendingRequest(request)
            return
        }

        switch request.context.coalescing {
        case .enqueue:
            appendPendingRequest(request)
        case .keepFirst:
            let existingID = activeRequestKey == key
                ? activeTransitionID
                : queuedRequests.first(where: { $0.context.requestKey == key })?.id
            guard let existingID else {
                appendPendingRequest(request)
                return
            }
            request.continuation.resume(
                returning: reject(
                    request.id,
                    reason: .coalesced(existingTransition: existingID),
                    context: request.context,
                    action: request.action
                )
            )
        case .replacePending:
            guard let index = queuedRequests.firstIndex(where: {
                $0.context.requestKey == key
            }) else {
                appendPendingRequest(request)
                return
            }
            let replaced = queuedRequests[index]
            queuedRequests[index] = request
            runtimeDependencies.didQueueRequest(request.id)
            replaced.continuation.resume(
                returning: reject(
                    replaced.id,
                    reason: .superseded(replacementTransition: request.id),
                    context: replaced.context,
                    action: replaced.action
                )
            )
        }
    }

    private func appendPendingRequest(_ request: QueuedRouterRequest<R>) {
        guard queuedRequests.count >= maximumPendingRequestCount else {
            queuedRequests.append(request)
            runtimeDependencies.didQueueRequest(request.id)
            return
        }

        switch requestOverflowStrategy {
        case .rejectNewest:
            request.continuation.resume(
                returning: reject(
                    request.id,
                    reason: .queueOverflow(limit: maximumPendingRequestCount),
                    context: request.context,
                    action: request.action
                )
            )
        case .discardOldest:
            guard !queuedRequests.isEmpty else {
                request.continuation.resume(
                    returning: reject(
                        request.id,
                        reason: .queueOverflow(limit: maximumPendingRequestCount),
                        context: request.context,
                        action: request.action
                    )
                )
                return
            }
            let discarded = queuedRequests.removeFirst()
            discarded.continuation.resume(
                returning: reject(
                    discarded.id,
                    reason: .queueOverflow(limit: maximumPendingRequestCount),
                    context: discarded.context,
                    action: discarded.action
                )
            )
            queuedRequests.append(request)
            runtimeDependencies.didQueueRequest(request.id)
        }
    }

    func finishExecution(_ id: RouterTransitionID) {
        guard activeTransitionID == id else { return }
        activeTransitionID = nil
        activeRequestKey = nil
        activeQueuedExecutionTask = nil
        activePolicyRaces.removeValue(forKey: id)
        cancelledRequestIDs.remove(id)
        resumeRequestCompletionWaiters(for: id)
        startNextRequestIfNeeded()
    }

    func waitUntilRequestFinishes(_ id: RouterTransitionID) async {
        guard activeTransitionID == id || queuedRequests.contains(where: { $0.id == id }) else {
            return
        }
        await withCheckedContinuation { continuation in
            requestCompletionWaiters[id, default: []].append(continuation)
        }
    }

    private func resumeRequestCompletionWaiters(for id: RouterTransitionID) {
        let waiters = requestCompletionWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume() }
    }

    private func startNextRequestIfNeeded() {
        guard activeTransitionID == nil else { return }
        while !queuedRequests.isEmpty {
            let request = queuedRequests.removeFirst()
            if cancelledRequestIDs.remove(request.id) != nil {
                request.continuation.resume(
                    returning: reject(
                        request.id,
                        reason: .cancelled,
                        context: request.context,
                        action: request.action
                    )
                )
                continue
            }
            activeTransitionID = request.id
            activeRequestKey = request.context.requestKey
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.execute(
                    request.action,
                    context: request.context,
                    expectedRevision: request.expectedRevision,
                    bypassesPolicies: request.bypassesPolicies,
                    startingPolicyIndex: request.startingPolicyIndex,
                    transitionID: request.id,
                    requestSemantics: request.semantics,
                    executionPrecondition: request.executionPrecondition,
                    executionPreparation: request.executionPreparation,
                    deferredResumePreparation: request.deferredResumePreparation
                )
                request.continuation.resume(returning: outcome)
            }
            activeQueuedExecutionTask = task
            if cancelledRequestIDs.contains(request.id) {
                task.cancel()
            }
            return
        }
    }
}
