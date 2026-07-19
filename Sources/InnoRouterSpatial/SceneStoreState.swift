// MARK: - SceneStoreState.swift
// InnoRouterSpatial — internal state machine backing the spatial
// scene surface.

import Foundation

import InnoRouterCore

internal struct ScenePendingRequest<R: Route>: Equatable {
    internal let id: UUID
    internal let intent: SceneIntent<R>
}

internal struct SceneClaimedRequest<R: Route>: Equatable {
    internal enum Status: Equatable {
        case active
        case superseded
        case awaitingSupersededImmersiveOpenCleanup
    }

    internal let request: ScenePendingRequest<R>
    internal var status: Status
}

internal enum SceneClaimCompletion<R: Route>: Equatable {
    case broadcast(SceneEvent<R>)
    case cleanupSupersededImmersiveOpen
    case none
}

internal struct SceneStoreState<R: Route>: Equatable {
    internal var queuedRequests: [ScenePendingRequest<R>]
    internal var claimedRequest: SceneClaimedRequest<R>?
    private var inventory: SceneInventory<R>

    internal init(
        currentScene: ScenePresentation<R>? = nil,
        pendingIntent: SceneIntent<R>? = nil
    ) {
        self.queuedRequests = pendingIntent.map {
            [ScenePendingRequest(id: UUID(), intent: $0)]
        } ?? []
        self.claimedRequest = nil
        self.inventory = SceneInventory()

        if let currentScene {
            inventory.activate(currentScene)
        }
    }

    internal var currentScene: ScenePresentation<R>? {
        inventory.currentScene
    }

    private var claimableHeadRequest: ScenePendingRequest<R>? {
        guard claimedRequest == nil else {
            return nil
        }

        return queuedRequests.first
    }

    internal var pendingIntent: SceneIntent<R>? {
        claimableHeadRequest?.intent
    }

    internal var currentPendingRequestID: UUID? {
        claimableHeadRequest?.id
    }

    internal var currentClaimedRequestID: UUID? {
        claimedRequest?.request.id
    }

    internal var queuedIntents: [SceneIntent<R>] {
        queuedRequests.map(\.intent)
    }

    internal var activeScenes: [ScenePresentation<R>] {
        inventory.activeScenes
    }

    internal var snapshot: SceneStoreSnapshot<R> {
        inventory.snapshot
    }

    internal mutating func requestOpen(_ presentation: ScenePresentation<R>) -> [SceneEvent<R>] {
        enqueueIntent(.open(presentation))
    }

    internal mutating func requestDismissImmersive() -> [SceneEvent<R>] {
        let intent = SceneIntent<R>.dismissImmersive
        if inventory.activeImmersive == nil, hasClaimedImmersiveRequest == false {
            if let cancellationEvent = consumeQueuedOpenCanceled(by: intent) {
                return [cancellationEvent]
            }

            return [
                .rejected(
                    intent,
                    reason: snapshot.hasActiveScenes ? .activeSceneMismatch : .nothingActive
                )
            ]
        }

        return enqueueIntent(intent)
    }

    internal mutating func requestDismissWindow(
        _ presentation: ScenePresentation<R>
    ) -> [SceneEvent<R>] {
        precondition(
            presentation.isWindowLike,
            "SceneStoreState.requestDismissWindow expects a window or volumetric presentation."
        )

        let intent = SceneIntent<R>.dismissWindow(presentation)
        if queuedRequests.contains(where: { $0.intent == intent }) {
            return []
        }

        guard inventory.contains(presentation) else {
            if let cancellationEvent = consumeQueuedOpenCanceled(by: intent) {
                return [cancellationEvent]
            }

            return [
                .rejected(
                    intent,
                    reason: .sceneInstanceNotActive
                )
            ]
        }

        return enqueueIntent(intent)
    }

    internal mutating func claimPendingRequest(_ requestID: UUID) -> SceneIntent<R>? {
        guard claimedRequest == nil else {
            return nil
        }
        guard let pendingRequest = queuedRequests.first, pendingRequest.id == requestID else {
            return nil
        }

        queuedRequests.removeFirst()
        claimedRequest = SceneClaimedRequest(request: pendingRequest, status: .active)
        return pendingRequest.intent
    }

    internal mutating func attach(_ presentation: ScenePresentation<R>) {
        inventory.activate(presentation)
    }

    internal mutating func detach(_ presentation: ScenePresentation<R>) {
        inventory.deactivate(presentation)
    }

    internal func presentationForAttachment(
        declaration: SceneDeclaration<R>,
        instanceID: UUID?
    ) -> ScenePresentation<R> {
        if let instanceID {
            return declaration.presentation(id: instanceID)
        }

        if let activeImmersive = inventory.activeImmersive,
           declaration.matches(activeImmersive) {
            return activeImmersive
        }

        let inFlightRequests = [
            claimedRequest?.request
        ]

        for request in inFlightRequests {
            guard let presentation = request?.intent.openedPresentation else {
                continue
            }
            guard presentation.isImmersive, declaration.matches(presentation) else {
                continue
            }
            return presentation
        }

        for request in queuedRequests {
            guard let presentation = request.intent.openedPresentation else {
                continue
            }
            guard presentation.isImmersive, declaration.matches(presentation) else {
                continue
            }
            return presentation
        }

        return declaration.presentation()
    }

    internal func presentationForImmersiveOpen(
        route: R,
        style: ImmersiveStyle
    ) -> ScenePresentation<R> {
        let candidates = [
            inventory.activeImmersive,
            claimedRequest?.request.intent.openedPresentation
        ] + queuedRequests.map(\.intent.openedPresentation)

        for candidate in candidates {
            guard let candidate else {
                continue
            }
            guard case .immersive(let candidateRoute, let candidateStyle, _) = candidate else {
                continue
            }
            guard candidateRoute == route, candidateStyle == style else {
                continue
            }
            return candidate
        }

        return .immersive(route, style: style)
    }

    internal mutating func completeOpen(
        _ presentation: ScenePresentation<R>,
        accepted: Bool,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        guard let requestID else {
            return nil
        }
        guard let claimedRequest, claimedRequest.request.id == requestID else {
            return nil
        }
        guard claimedRequest.request.intent == .open(presentation) else {
            return nil
        }

        switch claimedRequest.status {
        case .active:
            self.claimedRequest = nil

            let event: SceneEvent<R>
            if accepted {
                inventory.activate(presentation)
                event = .presented(presentation)
            } else {
                event = .rejected(.open(presentation), reason: .environmentReturnedFailure)
            }

            return .broadcast(event)

        case .superseded:
            if accepted, needsImmersiveCleanupAfterSupersededOpen(of: presentation) {
                self.claimedRequest?.status = .awaitingSupersededImmersiveOpenCleanup
                return .cleanupSupersededImmersiveOpen
            }

            self.claimedRequest = nil
            return SceneClaimCompletion.none

        case .awaitingSupersededImmersiveOpenCleanup:
            return nil
        }
    }

    internal mutating func finishSupersededImmersiveOpenCleanup(
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        guard let requestID else {
            return nil
        }
        guard let claimedRequest, claimedRequest.request.id == requestID else {
            return nil
        }
        guard claimedRequest.status == .awaitingSupersededImmersiveOpenCleanup else {
            return nil
        }

        let cleanedUpPresentation = claimedRequest.request.intent.openedPresentation
        self.claimedRequest = nil
        inventory.clearImmersive()

        if let cleanedUpPresentation, consumeQueuedDismissImmersiveIfPresent() {
            return .broadcast(.dismissed(cleanedUpPresentation))
        }

        return SceneClaimCompletion.none
    }

    internal mutating func completeDismissal(
        of presentation: ScenePresentation<R>,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        guard let requestID else {
            return nil
        }
        guard let claimedRequest, claimedRequest.request.id == requestID else {
            return nil
        }
        guard claimedRequest.request.intent == dismissalIntent(for: presentation) else {
            return nil
        }

        let status = claimedRequest.status
        self.claimedRequest = nil

        if status == .active {
            inventory.deactivate(presentation)
            return .broadcast(.dismissed(presentation))
        }

        silentlyReconcileSupersededDismissalIfNeeded(of: presentation, status: status)
        return SceneClaimCompletion.none
    }

    internal mutating func completeRejection(
        for intent: SceneIntent<R>,
        reason: SceneRejectionReason,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        guard let requestID else {
            return nil
        }
        guard let claimedRequest, claimedRequest.request.id == requestID else {
            return nil
        }
        guard claimedRequest.request.intent == intent else {
            return nil
        }

        let status = claimedRequest.status
        self.claimedRequest = nil

        if status == .active {
            return .broadcast(.rejected(intent, reason: reason))
        }

        return SceneClaimCompletion.none
    }

    private func needsImmersiveCleanupAfterSupersededOpen(
        of presentation: ScenePresentation<R>
    ) -> Bool {
        guard presentation.isImmersive else {
            return false
        }

        return inventory.activeImmersive?.id != presentation.id
    }

    internal func canDropFollowUpDismissAfterSupersedingPendingOpen(
        pendingIntent: SceneIntent<R>,
        with newIntent: SceneIntent<R>
    ) -> Bool {
        guard let pendingPresentation = pendingIntent.openedPresentation else {
            return false
        }
        guard newIntent.dismissesSameScene(as: pendingPresentation) else {
            return false
        }

        switch newIntent {
        case .open:
            return false
        case .dismissImmersive:
            return inventory.activeImmersive == nil
        case .dismissWindow(let presentation):
            return inventory.hasWindow(id: presentation.id) == false
        }
    }

    private mutating func silentlyReconcileSupersededDismissalIfNeeded(
        of presentation: ScenePresentation<R>,
        status: SceneClaimedRequest<R>.Status
    ) {
        guard status != .active else {
            return
        }
        guard presentation.isImmersive else {
            return
        }

        inventory.clearImmersive()
    }

    private func dismissalIntent(
        for presentation: ScenePresentation<R>
    ) -> SceneIntent<R> {
        switch presentation {
        case .window, .volumetric:
            return .dismissWindow(presentation)
        case .immersive:
            return .dismissImmersive
        }
    }
}
