// MARK: - SceneStore+RequestCompletion.swift
// InnoRouterSpatial — claimed request completion coordination.

#if os(visionOS)

import Foundation

import InnoRouterCore

extension SceneStore {
    @discardableResult
    internal func completeClaimedOpen(
        _ presentation: ScenePresentation<R>,
        accepted: Bool,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        completeClaimedRequest {
            $0.completeOpen(
                presentation,
                accepted: accepted,
                requestID: requestID
            )
        }
    }

    @discardableResult
    internal func completeClaimedDismissal(
        of presentation: ScenePresentation<R>,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        completeClaimedRequest {
            $0.completeDismissal(
                of: presentation,
                requestID: requestID
            )
        }
    }

    @discardableResult
    internal func completeClaimedRejection(
        for intent: SceneIntent<R>,
        reason: SceneRejectionReason,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        completeClaimedRequest {
            $0.completeRejection(
                for: intent,
                reason: reason,
                requestID: requestID
            )
        }
    }

    @discardableResult
    internal func finishSupersededImmersiveOpenCleanup(
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        completeClaimedRequest {
            $0.finishSupersededImmersiveOpenCleanup(requestID: requestID)
        }
    }

    private func completeClaimedRequest(
        _ mutation: (inout SceneStoreState<R>) -> SceneClaimCompletion<R>?
    ) -> SceneClaimCompletion<R>? {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        guard let completion = mutation(&state) else {
            return nil
        }

        syncFromState()
        broadcast(completion)
        signalDispatchIfNeeded(
            previousPendingRequestID: previousPendingRequestID,
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
        return completion
    }
}

#endif
