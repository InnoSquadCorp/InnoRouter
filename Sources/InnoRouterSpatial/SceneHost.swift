// MARK: - SceneHost.swift
// InnoRouterSpatial — visionOS-only host that bridges SceneStore to
// SwiftUI's spatial scene actions (openWindow / openImmersiveSpace /
// dismissImmersiveSpace / dismissWindow).
// Copyright © 2026 Inno Squad. All rights reserved.

// MARK: - Platform: This host reads visionOS-specific EnvironmentValues
// (`openImmersiveSpace`, `dismissImmersiveSpace`). It therefore exists
// only on visionOS.
#if os(visionOS)

import Foundation
import SwiftUI

import InnoRouterCore

@MainActor
internal struct SceneHostRegistration<R: Route> {
    internal let store: SceneStore<R>
    internal let dispatcherToken: UUID
    internal let scenes: SceneRegistry<R>
    internal let attachedTo: R
    internal let instanceID: UUID?

    @discardableResult
    internal func activate() -> Bool {
        store.registerSceneLifecycle(
            route: attachedTo,
            scenes: scenes,
            instanceID: instanceID,
            token: dispatcherToken
        )
        return store.registerDispatcherHost(dispatcherToken)
    }

    internal func deactivate(dispatcherOwned: Bool) {
        store.unregisterSceneLifecycle(dispatcherToken)
        if dispatcherOwned {
            store.unregisterDispatcherHost(dispatcherToken)
        }
    }
}

@MainActor
internal enum SceneHostSignal {
    case dispatchRequested
    case dispatcherChanged
}

@MainActor
internal func handleSceneHostSignal<R: Route>(
    _ signal: SceneHostSignal,
    isDormant: inout Bool,
    registration: SceneHostRegistration<R>,
    spawnDispatchTask: () -> Void
) {
    switch signal {
    case .dispatchRequested:
        guard !isDormant else { return }
        spawnDispatchTask()

    case .dispatcherChanged:
        guard isDormant else { return }
        let didRegister = registration.activate()
        isDormant = !didRegister
        guard didRegister else { return }
        spawnDispatchTask()
    }
}

/// Primary dispatcher for a ``SceneStore`` on visionOS.
///
/// `SceneHost` is the single source of authority for every
/// `openWindow` / `openImmersiveSpace` / `dismissImmersiveSpace` /
/// `dismissWindow` call InnoRouter issues. When attached to a scene
/// root, it reads those actions from SwiftUI's environment, claims
/// pending intents from the store, runs the async dispatch loop, and
/// commits results back through `completeClaimedOpen` /
/// `completeClaimedDismissal` / `completeClaimedRejection`.
///
/// Contract:
///
/// - **Designate one scene declaration as the host scene.** Every live root
///   produced by a value-based `WindowGroup` reconciles its own inventory
///   membership, while one root is elected to dispatch. Secondary roots receive a
///   ``SceneEvent/hostRegistrationRejected(reason:)`` event with
///   ``SceneRejectionReason/duplicateHostRegistration`` and stay
///   dormant for dispatch only. They do not crash the app, so SwiftUI scene
///   rehydration / hot-reload flows that momentarily overlap two
///   hosts are safe. Dormant hosts only retry registration after the
///   elected dispatcher changes; plain request traffic does not
///   re-emit duplicate-host diagnostics.
/// - **Do not pair it with a ``SceneAnchor`` on the same scene.** The
///   host already reconciles its own scene's lifecycle; adding an
///   anchor registers a redundant fallback dispatcher on a scene the
///   host owns.
/// - **Every non-host scene should attach a ``SceneAnchor`` instead**
///   so system-driven appear/disappear events keep
///   ``SceneStore/currentScene`` and the internal inventory in sync.
///
/// Use one of the attached-scene convenience wrappers
/// ``SwiftUI/View/innoRouterSceneHost(_:scenes:attachedTo:)`` or
/// ``SwiftUI/View/innoRouterSceneHost(_:scenes:attachedTo:instanceID:)``
/// instead of instantiating the modifier directly.
internal struct SceneHost<R: Route>: ViewModifier {
    @Bindable private var store: SceneStore<R>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var dispatcherToken = UUID()
    @State private var isDormant: Bool = false
    @State private var dispatchTask: Task<Void, Never>?
    private let scenes: SceneRegistry<R>
    private let attachedTo: R
    private let instanceID: UUID?

    /// Creates a scene host that also reconciles the host scene's own
    /// inventory membership.
    ///
    /// This overload is for immersive host scenes. Window and volumetric
    /// host scenes should use the `instanceID` overload so the store
    /// reconciles the exact value-based `WindowGroup` instance.
    ///
    /// - Parameters:
    ///   - store: the scene store driving this host.
    ///   - scenes: scene declarations shared with the app's
    ///     `WindowGroup` / `ImmersiveSpace` definitions.
    ///   - attachedTo: the route declared for the containing scene.
    internal init(
        store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R
    ) {
        self.init(
            store: store,
            scenes: scenes,
            attachedTo: attachedTo,
            instanceID: nil
        )
    }

    /// Creates a scene host that also reconciles a specific window or
    /// volumetric scene instance.
    ///
    /// Pass the value supplied by `WindowGroup(id:for:...)` so the host
    /// scene does not also need a redundant same-scene ``SceneAnchor``.
    internal init(
        store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R,
        instanceID: UUID
    ) {
        self.init(
            store: store,
            scenes: scenes,
            attachedTo: attachedTo,
            instanceID: Optional(instanceID)
        )
    }

    private init(
        store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R,
        instanceID: UUID?
    ) {
        guard let declaration = scenes.declaration(for: attachedTo) else {
            preconditionFailure(
                "SceneHost requires attachedTo to be declared in scenes. Missing route: \(String(describing: attachedTo))"
            )
        }
        if instanceID == nil {
            switch declaration.kind {
            case .window, .volumetric:
                preconditionFailure(
                    "SceneHost for window or volumetric scenes requires an instanceID. " +
                    "Declare the scene with WindowGroup(id:for:defaultValue:) and use " +
                    ".innoRouterSceneHost(_:scenes:attachedTo:instanceID:)."
                )
            case .immersive:
                break
            }
        }

        self.store = store
        self.scenes = scenes
        self.attachedTo = attachedTo
        self.instanceID = instanceID
    }

    internal func body(content: Content) -> some View {
        content
            .onAppear {
                // If another SceneHost is already primary the store
                // returns false and broadcasts
                // `.hostRegistrationRejected` — stay dormant instead of
                // crashing so SwiftUI scene rehydration / hot-reload
                // flows that briefly overlap two hosts don't take the
                // app down.
                activateIfPossible()
            }
            .onDisappear {
                // Cancel any in-flight dispatch first. The driver checks
                // Task.isCancelled after every async environment call
                // and abandons an outstanding claim with
                // `.hostTornDownDuringDispatch` instead of silently
                // committing an outcome the next dispatcher has no way
                // to reconcile.
                dispatchTask?.cancel()
                dispatchTask = nil

                // Inventory ownership is independent from dispatcher
                // election. Dormant hosts still represent live scene roots
                // and must unregister that lifecycle token on teardown.
                registration.deactivate(dispatcherOwned: !isDormant)
            }
            .onChange(of: store.dispatchSignal) { _, _ in
                // Dormant hosts ignore plain dispatch traffic so one
                // overlap collision does not re-register and re-emit
                // `.duplicateHostRegistration` for every new request.
                handleSceneHostSignal(
                    .dispatchRequested,
                    isDormant: &isDormant,
                    registration: registration,
                    spawnDispatchTask: spawnDispatchTask
                )
            }
            .onChange(of: store.dispatcherSignal) { _, _ in
                handleSceneHostSignal(
                    .dispatcherChanged,
                    isDormant: &isDormant,
                    registration: registration,
                    spawnDispatchTask: spawnDispatchTask
                )
            }
            .sceneRouterAuthority(store: store, scenes: scenes)
    }

    @MainActor
    private func spawnDispatchTask() {
        // Replace any in-flight task with a fresh dispatcher so the
        // view still owns the cancellation handle held by onDisappear.
        dispatchTask?.cancel()
        dispatchTask = Task { @MainActor in
            await dispatchPendingRequests()
        }
    }

    @MainActor
    private func activateIfPossible() {
        let didRegister = registration.activate()
        isDormant = !didRegister
        guard didRegister else { return }
        spawnDispatchTask()
    }

    private var registration: SceneHostRegistration<R> {
        SceneHostRegistration(
            store: store,
            dispatcherToken: dispatcherToken,
            scenes: scenes,
            attachedTo: attachedTo,
            instanceID: instanceID
        )
    }

    @MainActor
    private func dispatchPendingRequests() async {
        await SceneDispatchDriver(
            store: store,
            scenes: scenes,
            dispatcherToken: dispatcherToken,
            capability: .primaryHost,
            openWindow: { id, value in openWindow(id: id, value: value) },
            openImmersiveSpace: { id in await openImmersiveSpace(id: id) },
            dismissImmersiveSpace: { await dismissImmersiveSpace() },
            dismissWindow: { id, value in dismissWindow(id: id, value: value) }
        ).run()
    }
}

public extension View {
    /// Attaches the primary scene host and also registers the containing
    /// scene in the store's active inventory.
    ///
    /// Use this overload for the scene that physically hosts the
    /// dispatcher so ``SceneStore/currentScene`` and window dismissal
    /// requests stay accurate without adding a redundant same-scene
    /// `innoRouterSceneAnchor`. This overload is for immersive host scenes;
    /// windows and volumetric scenes should use the `instanceID`
    /// overload.
    func innoRouterSceneHost<R: Route>(
        _ store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R
    ) -> some View {
        modifier(SceneHost(store: store, scenes: scenes, attachedTo: attachedTo))
    }

    /// Attaches the primary scene host to a specific window or volumetric
    /// instance using the `UUID` supplied by a value-based `WindowGroup`.
    func innoRouterSceneHost<R: Route>(
        _ store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R,
        instanceID: UUID
    ) -> some View {
        modifier(
            SceneHost(
                store: store,
                scenes: scenes,
                attachedTo: attachedTo,
                instanceID: instanceID
            )
        )
    }
}

#endif
