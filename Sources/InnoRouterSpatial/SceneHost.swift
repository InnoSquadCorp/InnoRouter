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
    internal let attachedPresentation: ScenePresentation<R>?

    @discardableResult
    internal func activate() -> Bool {
        let didRegister = store.registerDispatcherHost(dispatcherToken)
        guard didRegister else { return false }
        if let attachedPresentation {
            store.attachDeclaredScene(attachedPresentation)
        }
        return true
    }

    internal func deactivateIfOwned() {
        if let attachedPresentation {
            store.detachDeclaredScene(attachedPresentation)
        }
        store.unregisterDispatcherHost(dispatcherToken)
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
/// - **Attach exactly one `SceneHost` per ``SceneStore``.** Secondary
///   hosts receive a
///   ``SceneEvent/hostRegistrationRejected(reason:)`` event with
///   ``SceneRejectionReason/duplicateHostRegistration`` and stay
///   dormant. They do not crash the app, so SwiftUI scene
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
/// Use one of the convenience wrappers
/// ``SwiftUI/View/innoRouterSceneHost(_:scenes:)`` or
/// ``SwiftUI/View/innoRouterSceneHost(_:scenes:attachedTo:instanceID:)`` instead
/// of instantiating the modifier directly.
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
    private let attachedPresentation: ScenePresentation<R>?

    /// Creates a scene host.
    ///
    /// - Parameters:
    ///   - store: the scene store driving this host.
    ///   - scenes: scene declarations shared with the app's
    ///     `WindowGroup` / `ImmersiveSpace` definitions.
    internal init(store: SceneStore<R>, scenes: SceneRegistry<R>) {
        self.init(store: store, scenes: scenes, attachedPresentation: nil)
    }

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

        self.init(
            store: store,
            scenes: scenes,
            attachedPresentation: instanceID.map {
                declaration.presentation(id: $0)
            } ?? declaration.presentation()
        )
    }

    private init(
        store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedPresentation: ScenePresentation<R>?
    ) {
        self.store = store
        self.scenes = scenes
        self.attachedPresentation = attachedPresentation
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

                // Only unregister if this host actually owned the
                // primary slot. A dormant host never registered and must
                // not disturb the live primary's registration.
                guard !isDormant else { return }
                registration.deactivateIfOwned()
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
            attachedPresentation: attachedPresentation
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
    /// Attaches the primary scene host that bridges `store` to SwiftUI's
    /// spatial scene environment actions.
    ///
    /// Available on visionOS only. On other platforms this modifier is
    /// not declared; `SceneStore` and this host modifier exist only behind
    /// `#if os(visionOS)`.
    func innoRouterSceneHost<R: Route>(
        _ store: SceneStore<R>,
        scenes: SceneRegistry<R>
    ) -> some View {
        modifier(SceneHost(store: store, scenes: scenes))
    }

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
