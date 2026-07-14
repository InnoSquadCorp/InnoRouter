// MARK: - SceneDispatchDriver.swift
// InnoRouterSpatial — shared visionOS-only dispatch loop for SceneHost
// and SceneAnchor.
// Copyright © 2026 Inno Squad. All rights reserved.

#if os(visionOS)

import Foundation
import SwiftUI

import InnoRouterCore

internal struct SceneDispatchDriver<R: Route> {
    internal let store: SceneStore<R>
    internal let scenes: SceneRegistry<R>
    internal let dispatcherToken: UUID
    internal let capability: SceneDispatchCapability<R>
    internal let openWindow: (String, UUID) -> Void
    internal let openImmersiveSpace: (String) async -> OpenImmersiveSpaceAction.Result
    internal let dismissImmersiveSpace: () async -> Void
    internal let dismissWindow: (String, UUID) -> Void

    @MainActor
    internal func run() async {
        dispatchLoop: while
            !Task.isCancelled,
            let requestID = store.currentPendingRequestID,
            let intent = store.claimPendingRequest(
                requestID,
                dispatcherToken: dispatcherToken
            )
        {
            let resolution = SceneIntentResolver(scenes: scenes)
                .resolve(intent, state: store.snapshot)

            // Fallback anchors must not commit cross-scene opens — they
            // don't have authority over scenes other than their own, and a
            // silent success would leave the store reporting "presented"
            // for a window that never appeared.
            if case .fallbackAnchor(let attachedPresentation) = capability,
               !resolution.isServiceableByFallback(
                   attachedTo: attachedPresentation,
                   declaredIn: scenes
               ) {
                _ = store.completeClaimedRejection(
                    for: intent,
                    reason: .fallbackCannotDispatch,
                    requestID: requestID
                )
                continue
            }

            switch resolution {
            case .openWindow(let id, let value, let presentation):
                openWindow(id, value)
                _ = store.completeClaimedOpen(
                    presentation,
                    accepted: true,
                    requestID: requestID
                )

            case .openImmersive(let id, let presentation):
                let result = await openImmersiveSpace(id)

                // If the host's dispatch Task was cancelled (the owning
                // view disappeared, or a signal-driven restart replaced
                // us) while we were awaiting the async opener, abandon
                // the claim rather than committing a result the next
                // dispatcher has no way to reconcile.
                if Task.isCancelled {
                    if result == .opened,
                       store.snapshot.activeImmersive != presentation {
                        // Duplicate re-opens can return `.opened` for an
                        // already committed immersive scene. Dismissing in
                        // that case would close the live scene while the
                        // store correctly keeps it active.
                        await dismissImmersiveSpace()
                    }
                    _ = store.completeClaimedRejection(
                        for: intent,
                        reason: .hostTornDownDuringDispatch,
                        requestID: requestID
                    )
                    break dispatchLoop
                }

                let completion = store.completeClaimedOpen(
                    presentation,
                    accepted: result == .opened,
                    requestID: requestID
                )

                if completion == .cleanupSupersededImmersiveOpen {
                    await dismissImmersiveSpace()

                    // The environment dismissal has completed even when
                    // cancellation arrived while it was suspended. Reconcile
                    // the cleanup before leaving so the superseded claim
                    // cannot permanently block queued requests.
                    _ = store.finishSupersededImmersiveOpenCleanup(requestID: requestID)

                    if Task.isCancelled {
                        break dispatchLoop
                    }
                }

            case .dismissWindow(let id, let value, let presentation):
                dismissWindow(id, value)
                _ = store.completeClaimedDismissal(of: presentation, requestID: requestID)

            case .dismissImmersive(let presentation):
                await dismissImmersiveSpace()
                if Task.isCancelled {
                    _ = store.completeClaimedRejection(
                        for: intent,
                        reason: .hostTornDownDuringDispatch,
                        requestID: requestID
                    )
                    break dispatchLoop
                }
                _ = store.completeClaimedDismissal(of: presentation, requestID: requestID)

            case .reject(let rejectedIntent, let reason):
                _ = store.completeClaimedRejection(
                    for: rejectedIntent,
                    reason: reason,
                    requestID: requestID
                )
            }
        }
    }
}

#endif
