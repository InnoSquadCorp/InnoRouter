// MARK: - SceneStore.swift
// InnoRouterSpatial — visionOS-only store for spatial scene presentations.
// Copyright © 2026 Inno Squad. All rights reserved.

// MARK: - Platform: Spatial scene intents (open window / open immersive
// space / dismiss immersive space) are only available on visionOS via
// SwiftUI's EnvironmentValues. The store therefore exists only on
// visionOS; consumers on other platforms should compile scene logic
// behind their own `#if os(visionOS)` branch.
#if os(visionOS)

import Foundation
import Observation

import InnoRouterCore

/// Store that coordinates spatial scene presentations on visionOS.
///
/// ``SceneStore`` owns the app's spatial scene inventory and publishes
/// open/dismiss intents that a ``SceneHost`` view translates into
/// SwiftUI environment actions (`openWindow`, `openImmersiveSpace`,
/// `dismissImmersiveSpace`, `dismissWindow`).
///
/// Usage sketch:
///
/// ```swift
/// private let spatialScenes = SceneRegistry<SpatialRoute>(
///     .window(.main, id: SpatialRoute.main.rawValue),
///     .immersive(.theatre, id: SpatialRoute.theatre.rawValue, style: .mixed)
/// )
///
/// @main
/// struct MyApp: App {
///     @State private var sceneStore = SceneStore<SpatialRoute>()
///
///     var body: some Scene {
///         WindowGroup(id: "main", for: UUID.self) { $sceneID in
///             MainView()
///                 .innoRouterSceneHost(
///                     sceneStore,
///                     scenes: spatialScenes,
///                     attachedTo: .main,
///                     instanceID: sceneID
///                 )
///         } defaultValue: {
///             UUID()
///         }
///         ImmersiveSpace(id: SpatialRoute.theatre.rawValue) {
///             TheatreView()
///                 .innoRouterSceneAnchor(
///                     sceneStore,
///                     scenes: spatialScenes,
///                     attachedTo: .theatre
///                 )
///         }
///     }
/// }
/// ```
@MainActor
@Observable
public final class SceneStore<R: Route> {
    @ObservationIgnored
    private var state: SceneStoreState<R>

    @ObservationIgnored
    private var dispatcherRegistry: SceneDispatcherRegistry

    /// Recency-ordered summary of the active scene inventory, or `nil`
    /// if nothing is active.
    public private(set) var currentScene: ScenePresentation<R>?

    /// Recency-ordered active scene inventory.
    public private(set) var activeScenes: [ScenePresentation<R>]

    internal private(set) var currentPendingRequestID: UUID?
    internal private(set) var currentClaimedRequestID: UUID?
    internal private(set) var dispatchSignal: UInt64
    internal private(set) var dispatcherSignal: UInt64

    @ObservationIgnored
    private let broadcaster: EventBroadcaster<SceneEvent<R>>

    /// Creates an empty scene store.
    public init() {
        let state = SceneStoreState<R>()
        self.state = state
        self.dispatcherRegistry = SceneDispatcherRegistry()
        self.currentScene = state.currentScene
        self.activeScenes = state.activeScenes
        self.currentPendingRequestID = state.currentPendingRequestID
        self.currentClaimedRequestID = state.currentClaimedRequestID
        self.dispatchSignal = 0
        self.dispatcherSignal = 0
        self.broadcaster = EventBroadcaster()
    }

    /// Async stream of every ``SceneEvent`` emitted by this store.
    public var events: AsyncStream<SceneEvent<R>> {
        broadcaster.stream()
    }

    /// Requests that the host open a regular window for `route` and
    /// returns the created scene handle.
    @discardableResult
    public func openWindow(_ route: R) -> ScenePresentation<R> {
        let presentation = ScenePresentation<R>.window(route)
        applyRequestMutation {
            $0.requestOpen(presentation)
        }
        return presentation
    }

    /// Requests that the host open a volumetric window for `route` and
    /// returns the created scene handle.
    @discardableResult
    public func openVolumetric(_ route: R, size: VolumetricSize? = nil) -> ScenePresentation<R> {
        let presentation = ScenePresentation<R>.volumetric(route, size: size)
        applyRequestMutation {
            $0.requestOpen(presentation)
        }
        return presentation
    }

    /// Requests that the host open an immersive space for `route`.
    public func openImmersive(_ route: R, style: ImmersiveStyle) {
        applyRequestMutation {
            $0.requestOpen(.immersive(route, style: style))
        }
    }

    /// Requests that the host dismiss the active immersive space.
    public func dismissImmersive() {
        applyRequestMutation {
            $0.requestDismissImmersive()
        }
    }

    /// Requests that the host dismiss the specific window instance.
    public func dismissWindow(_ presentation: ScenePresentation<R>) {
        precondition(
            presentation.isWindowLike,
            "SceneStore.dismissWindow expects a window or volumetric presentation."
        )
        applyRequestMutation {
            $0.requestDismissWindow(presentation)
        }
    }

    internal var snapshot: SceneStoreSnapshot<R> {
        state.snapshot
    }

    internal func attachDeclaredScene(_ presentation: ScenePresentation<R>) {
        state.attach(presentation)
        syncFromState()
    }

    @discardableResult
    internal func attachDeclaredScene(
        route: R,
        scenes: SceneRegistry<R>,
        instanceID: UUID?
    ) -> ScenePresentation<R> {
        let declaration = scenes.declaration(for: route)!
        let presentation = state.presentationForAttachment(
            declaration: declaration,
            instanceID: instanceID
        )
        state.attach(presentation)
        syncFromState()
        return presentation
    }

    internal func detachDeclaredScene(_ presentation: ScenePresentation<R>) {
        state.detach(presentation)
        syncFromState()
    }

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
            broadcaster.broadcast(
                .hostRegistrationRejected(reason: .duplicateHostRegistration)
            )
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

    @discardableResult
    internal func completeClaimedOpen(
        _ presentation: ScenePresentation<R>,
        accepted: Bool,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        guard let completion = state.completeOpen(
            presentation,
            accepted: accepted,
            requestID: requestID
        ) else {
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

    @discardableResult
    internal func completeClaimedDismissal(
        of presentation: ScenePresentation<R>,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        guard let completion = state.completeDismissal(
            of: presentation,
            requestID: requestID
        ) else {
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

    @discardableResult
    internal func completeClaimedRejection(
        for intent: SceneIntent<R>,
        reason: SceneRejectionReason,
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        guard let completion = state.completeRejection(
            for: intent,
            reason: reason,
            requestID: requestID
        ) else {
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

    @discardableResult
    internal func finishSupersededImmersiveOpenCleanup(
        requestID: UUID?
    ) -> SceneClaimCompletion<R>? {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken

        guard let completion = state.finishSupersededImmersiveOpenCleanup(requestID: requestID) else {
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

    private func syncFromState() {
        currentScene = state.currentScene
        activeScenes = state.activeScenes
        currentPendingRequestID = state.currentPendingRequestID
        currentClaimedRequestID = state.currentClaimedRequestID
    }

    private func applyRequestMutation(
        _ mutation: (inout SceneStoreState<R>) -> [SceneEvent<R>]
    ) {
        let previousPendingRequestID = currentPendingRequestID
        let previousElectedDispatcherToken = dispatcherRegistry.electedDispatcherToken
        let events = mutation(&state)

        syncFromState()
        broadcast(events)
        signalDispatchIfNeeded(
            previousPendingRequestID: previousPendingRequestID,
            previousElectedDispatcherToken: previousElectedDispatcherToken
        )
    }

    private func broadcast(_ events: [SceneEvent<R>]) {
        for event in events {
            broadcaster.broadcast(event)
        }
    }

    private func broadcast(_ completion: SceneClaimCompletion<R>) {
        if case .broadcast(let event) = completion {
            broadcaster.broadcast(event)
        }
    }

    private func signalDispatchIfNeeded(
        previousPendingRequestID: UUID?,
        previousElectedDispatcherToken: UUID?
    ) {
        guard currentClaimedRequestID == nil else {
            return
        }
        guard currentPendingRequestID != nil else {
            return
        }
        guard dispatcherRegistry.electedDispatcherToken != nil else {
            return
        }
        guard
            previousPendingRequestID != currentPendingRequestID ||
                previousElectedDispatcherToken != dispatcherRegistry.electedDispatcherToken
        else {
            return
        }

        dispatchSignal &+= 1
    }

    private func signalDispatcherChangeIfNeeded(
        previousElectedDispatcherToken: UUID?
    ) {
        guard previousElectedDispatcherToken != dispatcherRegistry.electedDispatcherToken else {
            return
        }

        dispatcherSignal &+= 1
    }

    isolated deinit {
        // EventBroadcaster's own isolated deinit will finish continuations.
        _ = broadcaster
    }
}

#endif
