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

internal struct SceneDispatcherRegistry: Equatable {
    internal private(set) var primaryHost: UUID?
    internal private(set) var fallbackAnchors: [UUID] = []

    internal var electedDispatcherToken: UUID? {
        primaryHost ?? fallbackAnchors.first
    }

    internal mutating func registerPrimaryHost(_ token: UUID) -> Bool {
        if let primaryHost, primaryHost != token {
            return false
        }

        primaryHost = token
        return true
    }

    internal mutating func unregisterPrimaryHost(_ token: UUID) {
        if primaryHost == token {
            primaryHost = nil
        }
    }

    internal mutating func registerFallbackAnchor(_ token: UUID) {
        if fallbackAnchors.contains(token) == false {
            fallbackAnchors.append(token)
        }
    }

    internal mutating func unregisterFallbackAnchor(_ token: UUID) {
        fallbackAnchors.removeAll { $0 == token }
    }

    internal func canClaim(_ token: UUID) -> Bool {
        electedDispatcherToken == token
    }
}

internal struct SceneStoreSnapshot<R: Route>: Equatable {
    internal let currentScene: ScenePresentation<R>?
    internal let activeScenes: [ScenePresentation<R>]
    internal let openWindowsByID: [UUID: ScenePresentation<R>]
    internal let activeImmersive: ScenePresentation<R>?

    internal var hasActiveScenes: Bool {
        !activeScenes.isEmpty
    }

    internal func windowPresentation(id: UUID) -> ScenePresentation<R>? {
        openWindowsByID[id]
    }

    internal func windowPresentations(for route: R) -> [ScenePresentation<R>] {
        activeScenes.filter { $0.route == route && $0.isWindowLike }
    }
}

internal struct SceneStoreState<R: Route>: Equatable {
    internal private(set) var currentScene: ScenePresentation<R>?
    internal private(set) var queuedRequests: [ScenePendingRequest<R>]
    internal private(set) var claimedRequest: SceneClaimedRequest<R>?

    private var openWindowsByID: [UUID: ScenePresentation<R>]
    private var activeImmersive: ScenePresentation<R>?
    private var activeScenesInRecencyOrder: [ScenePresentation<R>]

    internal init(
        currentScene: ScenePresentation<R>? = nil,
        pendingIntent: SceneIntent<R>? = nil
    ) {
        self.currentScene = nil
        self.queuedRequests = pendingIntent.map {
            [ScenePendingRequest(id: UUID(), intent: $0)]
        } ?? []
        self.claimedRequest = nil
        self.openWindowsByID = [:]
        self.activeImmersive = nil
        self.activeScenesInRecencyOrder = []

        if let currentScene {
            activate(currentScene)
        }
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
        activeScenesInRecencyOrder.filter { isActive($0) }
    }

    internal var snapshot: SceneStoreSnapshot<R> {
        SceneStoreSnapshot(
            currentScene: currentScene,
            activeScenes: activeScenes,
            openWindowsByID: openWindowsByID,
            activeImmersive: activeImmersive
        )
    }

    internal mutating func requestOpen(_ presentation: ScenePresentation<R>) -> [SceneEvent<R>] {
        enqueueIntent(.open(presentation))
    }

    internal mutating func requestDismissImmersive() -> [SceneEvent<R>] {
        let intent = SceneIntent<R>.dismissImmersive
        if activeImmersive == nil, hasClaimedImmersiveRequest == false {
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

        guard openWindowsByID[presentation.id] == presentation else {
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
        activate(presentation)
    }

    internal mutating func detach(_ presentation: ScenePresentation<R>) {
        deactivate(presentation)
    }

    internal func presentationForAttachment(
        declaration: SceneDeclaration<R>,
        instanceID: UUID?
    ) -> ScenePresentation<R> {
        if let instanceID {
            return declaration.presentation(id: instanceID)
        }

        if let activeImmersive, declaration.matches(activeImmersive) {
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
                activate(presentation)
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
        clearCommittedImmersiveState()

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
            deactivate(presentation)
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

    private func makePendingRequest(for intent: SceneIntent<R>) -> ScenePendingRequest<R> {
        ScenePendingRequest(id: UUID(), intent: intent)
    }

    private var hasClaimedImmersiveRequest: Bool {
        claimedRequest?.request.intent.isImmersiveOperation == true
    }

    private mutating func enqueueIntent(_ newIntent: SceneIntent<R>) -> [SceneEvent<R>] {
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

        guard let existingIndex = queuedRequests.firstIndex(where: { $0.intent.isImmersiveOperation }) else {
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

    private mutating func consumeQueuedOpenCanceled(
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

    private mutating func consumeQueuedDismissImmersiveIfPresent() -> Bool {
        guard let index = queuedRequests.firstIndex(where: { $0.intent == .dismissImmersive }) else {
            return false
        }

        queuedRequests.remove(at: index)
        return true
    }

    private func needsImmersiveCleanupAfterSupersededOpen(
        of presentation: ScenePresentation<R>
    ) -> Bool {
        guard presentation.isImmersive else {
            return false
        }

        return activeImmersive?.id != presentation.id
    }

    private func canDropFollowUpDismissAfterSupersedingPendingOpen(
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
            return activeImmersive == nil
        case .dismissWindow(let presentation):
            return openWindowsByID[presentation.id] == nil
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

        clearCommittedImmersiveState()
    }

    private mutating func activate(_ presentation: ScenePresentation<R>) {
        switch presentation {
        case .window, .volumetric:
            openWindowsByID[presentation.id] = presentation
        case .immersive:
            if let activeImmersive, activeImmersive.id != presentation.id {
                activeScenesInRecencyOrder.removeAll { $0.id == activeImmersive.id }
            }
            self.activeImmersive = presentation
        }

        touch(presentation)
        syncCurrentScene()
    }

    private mutating func clearCommittedImmersiveState() {
        activeImmersive = nil
        activeScenesInRecencyOrder.removeAll { $0.isImmersive }
        syncCurrentScene()
    }

    private mutating func deactivate(_ presentation: ScenePresentation<R>) {
        switch presentation {
        case .window, .volumetric:
            openWindowsByID.removeValue(forKey: presentation.id)
        case .immersive:
            if activeImmersive?.id == presentation.id {
                activeImmersive = nil
            }
        }

        activeScenesInRecencyOrder.removeAll { $0.id == presentation.id }
        syncCurrentScene()
    }

    private mutating func touch(_ presentation: ScenePresentation<R>) {
        activeScenesInRecencyOrder.removeAll { $0.id == presentation.id }
        activeScenesInRecencyOrder.append(presentation)
    }

    private mutating func syncCurrentScene() {
        activeScenesInRecencyOrder = activeScenes
        currentScene = activeScenesInRecencyOrder.last
    }

    private func isActive(_ presentation: ScenePresentation<R>) -> Bool {
        switch presentation {
        case .window, .volumetric:
            return openWindowsByID[presentation.id] == presentation
        case .immersive:
            return activeImmersive == presentation
        }
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
