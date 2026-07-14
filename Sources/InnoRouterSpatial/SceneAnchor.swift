// MARK: - SceneAnchor.swift
// InnoRouterSpatial — visionOS-only scene lifecycle reconciliation
// modifier for SceneStore inventory tracking.
// Copyright © 2026 Inno Squad. All rights reserved.

#if os(visionOS)

import Foundation
import SwiftUI

import InnoRouterCore

/// Lifecycle reconciler + restricted fallback dispatcher for a
/// ``SceneStore`` on visionOS.
///
/// `SceneAnchor` has two jobs:
///
/// 1. **Inventory reconciliation.** When the system opens or closes a
///    scene outside InnoRouter's explicit command path (for example
///    via Control Center, SwitchToApp, or session restoration),
///    the anchor's `onAppear` / `onDisappear` attach and detach the
///    presentation in the store's internal inventory so
///    ``SceneStore/currentScene`` stays honest.
/// 2. **Fallback dispatch (restricted).** When the primary
///    ``SceneHost`` scene is not currently live, any anchor on a
///    sibling scene can temporarily claim pending intents. Fallback
///    anchors are deliberately limited: they can only execute
///    **same-scene opens** (re-opens for the scene they are attached
///    to) and **any dismissal**. Cross-scene opens are rejected with
///    ``SceneRejectionReason/fallbackCannotDispatch`` so the queue
///    advances instead of silently committing a result from a
///    dispatcher that cannot actually reach the target scene.
///
/// Contract:
///
/// - **Attach one anchor per non-host scene.** Every
///   `WindowGroup` / `ImmersiveSpace` that participates in the
///   store's ``SceneRegistry`` — except the one hosting the
///   ``SceneHost`` — should carry a
///   ``SwiftUI/View/innoRouterSceneAnchor(_:scenes:attachedTo:)``.
/// - **Do not pair it with a ``SceneHost`` on the same scene.** The
///   host already reconciles its own scene.
/// - Anchors never emit public lifecycle events for inventory
///   transitions; only explicit command paths broadcast ``SceneEvent``.
internal struct SceneAnchor<R: Route>: ViewModifier {
    @Bindable private var store: SceneStore<R>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var dispatcherToken = UUID()
    @State private var attachedPresentation: ScenePresentation<R>?
    @State private var dispatchTask: Task<Void, Never>?
    private let scenes: SceneRegistry<R>
    private let attachedTo: R
    private let instanceID: UUID?

    /// Creates a scene anchor.
    ///
    /// - Parameters:
    ///   - store: the scene store whose inventory should track this
    ///     scene root.
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

    /// Creates a scene anchor for a specific window instance.
    ///
    /// Pass the value supplied by `WindowGroup(id:for:...)` so each
    /// window or volumetric root can reconcile the exact instance that
    /// SwiftUI opened.
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
                "SceneAnchor requires attachedTo to be declared in scenes. Missing route: \(String(describing: attachedTo))"
            )
        }
        if instanceID == nil {
            switch declaration.kind {
            case .window, .volumetric:
                preconditionFailure(
                    "SceneAnchor for window or volumetric scenes requires an instanceID. " +
                    "Declare the scene with WindowGroup(id:for:defaultValue:) and use " +
                    ".innoRouterSceneAnchor(_:scenes:attachedTo:instanceID:)."
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
                attachedPresentation = store.attachDeclaredScene(
                    route: attachedTo,
                    scenes: scenes,
                    instanceID: instanceID
                )
                store.registerFallbackDispatcher(dispatcherToken)
                spawnDispatchTask()
            }
            .onDisappear {
                // Cancel any in-flight dispatch so an outstanding claim
                // is released through `.hostTornDownDuringDispatch`
                // instead of silently completing against a scene that
                // is no longer in the view tree.
                dispatchTask?.cancel()
                dispatchTask = nil

                if let attachedPresentation {
                    store.detachDeclaredScene(attachedPresentation)
                    self.attachedPresentation = nil
                }
                store.unregisterFallbackDispatcher(dispatcherToken)
            }
            .onChange(of: store.dispatchSignal) { _, _ in
                spawnDispatchTask()
            }
    }

    @MainActor
    private func spawnDispatchTask() {
        // Replace any in-flight task with a fresh dispatcher so the
        // anchor still owns the cancellation handle held by onDisappear.
        dispatchTask?.cancel()
        dispatchTask = Task { @MainActor in
            await dispatchPendingRequests()
        }
    }

    @MainActor
    private func dispatchPendingRequests() async {
        guard let attachedPresentation else { return }
        await SceneDispatchDriver(
            store: store,
            scenes: scenes,
            dispatcherToken: dispatcherToken,
            capability: .fallbackAnchor(attachedTo: attachedPresentation),
            openWindow: { id, value in openWindow(id: id, value: value) },
            openImmersiveSpace: { id in await openImmersiveSpace(id: id) },
            dismissImmersiveSpace: { await dismissImmersiveSpace() },
            dismissWindow: { id, value in dismissWindow(id: id, value: value) }
        ).run()
    }
}

public extension View {
    /// Attaches a scene anchor that reconciles a scene root with a
    /// ``SceneStore`` inventory and provides fallback dispatch when no
    /// explicit host is alive.
    ///
    /// Available on visionOS only. On other platforms this modifier is
    /// not declared; `SceneStore` and the scene host/anchor modifiers exist
    /// only behind `#if os(visionOS)`. This overload is for immersive
    /// spaces; windows and volumetric scenes must use the `instanceID`
    /// overload.
    func innoRouterSceneAnchor<R: Route>(
        _ store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R
    ) -> some View {
        modifier(SceneAnchor(store: store, scenes: scenes, attachedTo: attachedTo))
    }

    /// Attaches a scene anchor to a specific window or volumetric
    /// instance using the `UUID` supplied by a value-based `WindowGroup`.
    func innoRouterSceneAnchor<R: Route>(
        _ store: SceneStore<R>,
        scenes: SceneRegistry<R>,
        attachedTo: R,
        instanceID: UUID
    ) -> some View {
        modifier(
            SceneAnchor(
                store: store,
                scenes: scenes,
                attachedTo: attachedTo,
                instanceID: instanceID
            )
        )
    }
}

#endif
