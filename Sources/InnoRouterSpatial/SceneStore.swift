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
/// open/dismiss intents that `innoRouterSceneHost` translates into
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
    internal var state: SceneStoreState<R>

    @ObservationIgnored
    internal var dispatcherRegistry: SceneDispatcherRegistry

    /// Live SwiftUI scene roots keyed by the stable token owned by their
    /// host or anchor modifier. Inventory lifetime is intentionally separate
    /// from dispatcher election: dormant hosts still represent live scenes,
    /// and overlapping roots for the same scene must detach only after the
    /// final owner disappears.
    @ObservationIgnored
    internal var lifecycleRegistry: SceneLifecycleRegistry<R>

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
        self.lifecycleRegistry = SceneLifecycleRegistry()
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

    /// Requests that the host open an immersive space for `route` and
    /// returns the request handle used to reconcile its lifecycle.
    @discardableResult
    public func openImmersive(
        _ route: R,
        style: ImmersiveStyle
    ) -> ScenePresentation<R> {
        let presentation = state.presentationForImmersiveOpen(route: route, style: style)
        applyRequestMutation {
            $0.requestOpen(presentation)
        }
        return presentation
    }

    /// Requests that the host dismiss the active immersive space.
    public func dismissImmersive() {
        applyRequestMutation {
            $0.requestDismissImmersive()
        }
    }

    /// Requests that the host dismiss the specific window instance.
    ///
    /// Passing an immersive presentation is rejected through ``events``
    /// with ``SceneRejectionReason/sceneDeclarationMismatch``. Use
    /// ``dismissImmersive()`` for immersive spaces.
    public func dismissWindow(_ presentation: ScenePresentation<R>) {
        applyRequestMutation {
            $0.requestDismissWindow(presentation)
        }
    }

    internal var snapshot: SceneStoreSnapshot<R> {
        state.snapshot
    }

    internal func syncFromState() {
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

    internal func broadcast(_ events: [SceneEvent<R>]) {
        for event in events {
            broadcaster.broadcast(event)
        }
    }

    internal func broadcast(_ completion: SceneClaimCompletion<R>) {
        if case .broadcast(let event) = completion {
            broadcaster.broadcast(event)
        }
    }

    internal func signalDispatchIfNeeded(
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

    internal func signalDispatcherChangeIfNeeded(
        previousElectedDispatcherToken: UUID?
    ) {
        guard previousElectedDispatcherToken != dispatcherRegistry.electedDispatcherToken else {
            return
        }

        dispatcherSignal &+= 1
    }
}

#endif
