// MARK: - SceneStore+Dispatch.swift
// InnoRouterSpatial — dispatcher registration and request claiming.

#if os(visionOS)

import Foundation

import InnoRouterCore

extension SceneStore {
    /// Registers `token` as the store's primary dispatcher host.
    ///
    /// Returns `true` when the host successfully becomes primary and
    /// should run its dispatch loop. Returns `false` when another
    /// ``SceneHost`` is already primary — the losing host should treat
    /// itself as dormant (no dispatch, no `unregisterDispatcherHost` on
    /// teardown), and a ``SceneEvent/hostRegistrationRejected(reason:)``
    /// with ``SceneRejectionReason/duplicateHostRegistration`` is
    /// broadcast so consumers see the collision.
    ///
    /// Previously this crashed via `preconditionFailure`, which made
    /// SwiftUI scene rehydration / hot-reload transitions unsafe in
    /// production. The recoverable return lets the two hosts race
    /// without taking the app down.
    @discardableResult
    internal func registerDispatcherHost(_ token: UUID) -> Bool {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        guard dispatcherRegistry.registerPrimaryHost(token) else {
            broadcast([.hostRegistrationRejected(reason: .duplicateHostRegistration)])
            return false
        }

        signalDispatchIfNeeded(
            previousPendingRequestID: previousPendingRequestID,
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
        signalDispatcherChangeIfNeeded(
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
        return true
    }

    internal func unregisterDispatcherHost(_ token: UUID) {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        dispatcherRegistry.unregisterPrimaryHost(token)

        signalDispatchIfNeeded(
            previousPendingRequestID: previousPendingRequestID,
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
        signalDispatcherChangeIfNeeded(
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
    }

    internal func registerFallbackDispatcher(_ token: UUID) {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        dispatcherRegistry.registerFallbackAnchor(token)

        signalDispatchIfNeeded(
            previousPendingRequestID: previousPendingRequestID,
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
        signalDispatcherChangeIfNeeded(
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
    }

    internal func unregisterFallbackDispatcher(_ token: UUID) {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        dispatcherRegistry.unregisterFallbackAnchor(token)

        signalDispatchIfNeeded(
            previousPendingRequestID: previousPendingRequestID,
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
        signalDispatcherChangeIfNeeded(
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
    }

    internal func claimPendingRequest(
        _ requestID: UUID,
        dispatcherToken: UUID
    ) -> SceneIntent<R>? {
        guard dispatcherRegistry.canClaim(dispatcherToken) else {
            return nil
        }
        guard let intent = state.claimPendingRequest(requestID) else {
            return nil
        }

        syncFromState()
        return intent
    }
}

#endif
