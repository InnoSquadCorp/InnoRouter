// MARK: - SceneStoreState+RequestQueue.swift
// InnoRouterSpatial — pending and claimed scene request queue transitions.

import Foundation

import InnoRouterCore

extension SceneStoreState {
    internal var hasClaimedImmersiveRequest: Bool {
        claimedRequest?.request.intent.isImmersiveOperation == true
    }

    internal mutating func enqueueIntent(_ newIntent: SceneIntent<R>) -> [SceneEvent<R>] {
        let claimedPreparation = prepareClaimedImmersiveForNewIntent(newIntent)
        var events = claimedPreparation.events
        guard claimedPreparation.shouldEnqueue else {
            return events
        }

        let queuedPreparation = prepareQueuedRequests(for: newIntent)
        events.append(contentsOf: queuedPreparation.events)
        guard let insertionIndex = queuedPreparation.insertionIndex else {
            return events
        }

        queuedRequests.insert(makePendingRequest(for: newIntent), at: insertionIndex)
        return events
    }

    internal mutating func consumeQueuedOpenCanceled(
        by dismissIntent: SceneIntent<R>
    ) -> SceneEvent<R>? {
        guard let index = queuedRequests.firstIndex(where: { request in
            guard let pendingPresentation = request.intent.openedPresentation else {
                return false
            }

            return dismissIntent.dismissesSameScene(as: pendingPresentation)
        }) else {
            return nil
        }

        let removedRequest = queuedRequests.remove(at: index)
        return .rejected(
            removedRequest.intent,
            reason: .supersededByNewerIntent
        )
    }

    internal mutating func consumeQueuedDismissImmersiveIfPresent() -> Bool {
        guard let index = queuedRequests.firstIndex(where: { $0.intent == .dismissImmersive }) else {
            return false
        }

        queuedRequests.remove(at: index)
        return true
    }

    private func makePendingRequest(for intent: SceneIntent<R>) -> ScenePendingRequest<R> {
        ScenePendingRequest(id: UUID(), intent: intent)
    }

    private mutating func prepareClaimedImmersiveForNewIntent(
        _ newIntent: SceneIntent<R>
    ) -> (events: [SceneEvent<R>], shouldEnqueue: Bool) {
        guard var claimedRequest else {
            return ([], true)
        }
        guard claimedRequest.request.intent.isImmersiveOperation else {
            return ([], true)
        }

        if claimedRequest.status == .active, claimedRequest.request.intent == newIntent {
            return ([], false)
        }

        if claimedRequest.status == .active {
            claimedRequest.status = .superseded
            self.claimedRequest = claimedRequest
            return (
                [
                    .rejected(
                        claimedRequest.request.intent,
                        reason: .supersededByNewerIntent
                    )
                ],
                true
            )
        }

        return ([], true)
    }

    private mutating func prepareQueuedRequests(
        for newIntent: SceneIntent<R>
    ) -> (events: [SceneEvent<R>], insertionIndex: Int?) {
        if queuedRequests.contains(where: { $0.intent == newIntent }) {
            return ([], nil)
        }

        guard newIntent.isImmersiveOperation else {
            return ([], queuedRequests.endIndex)
        }

        guard let existingIndex = queuedRequests.firstIndex(where: {
            $0.intent.isImmersiveOperation
        }) else {
            return ([], queuedRequests.endIndex)
        }

        let replacedRequest = queuedRequests.remove(at: existingIndex)
        let supersededEvent = SceneEvent<R>.rejected(
            replacedRequest.intent,
            reason: .supersededByNewerIntent
        )

        if canDropFollowUpDismissAfterSupersedingPendingOpen(
            pendingIntent: replacedRequest.intent,
            with: newIntent
        ) {
            return ([supersededEvent], nil)
        }

        return ([supersededEvent], existingIndex)
    }
}
