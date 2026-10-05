// MARK: - RouterSceneLifecycle.swift
// InnoRouterSwiftUI - native scene lifecycle reconciliation
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import SwiftUI

import InnoRouterCore

public extension View {
    /// Reconciles an interactively closed value-based window with its store.
    ///
    /// Attach this to the content of the matching
    /// `WindowGroup(id:for: UUID.self)`. A system-originated close removes only
    /// this window ID. If a router policy rejects the close while the same
    /// window remains authoritative, the native window is reopened.
    /// Explicit ownership replacement remounts this content and can reset
    /// scene-local view state without changing native scene identity.
    @MainActor
    func routerWindowLifecycle<R: RouterSceneRoute>(
        _ id: UUID,
        store: RouterStore<R>
    ) -> some View {
        let scope = store.scope(at: .window(id))
        return modifier(RouterWindowLifecycleModifier(id: id, store: store, scope: scope))
            .id(ObjectIdentifier(scope))
    }

    /// Reconciles an interactively dismissed immersive space with its store.
    ///
    /// Attach this to the matching `ImmersiveSpace` content. Rejected system
    /// dismissal is reopened only while the same immersive-space lifetime
    /// remains authoritative in canonical state.
    /// Explicit ownership replacement remounts this content and can reset
    /// scene-local view state without changing native scene identity.
    @MainActor
    func routerImmersiveSpaceLifecycle<R: RouterSceneRoute>(
        _ id: String,
        store: RouterStore<R>
    ) -> some View {
        let scope = store.scope(at: .immersiveSpace(id))
        return modifier(RouterImmersiveSpaceLifecycleModifier(
            id: id,
            lifecycleToken: store.state.immersiveSpace?.id == id
                ? store.immersiveSpaceLifecycleToken
                : nil,
            store: store,
            scope: scope
        ))
        .id(ObjectIdentifier(scope))
    }
}

@MainActor
private struct RouterWindowLifecycleModifier<R: RouterSceneRoute>: ViewModifier {
    let id: UUID
    let lifecycleToken: UUID?
    let store: RouterStore<R>
    // Retains the observed lifetime slot even when used without a Scene host.
    let scope: RouterScope<R>
    @State private var appearedLifetime: UUID?
    @State private var appearedRequestPrecondition: RouterRequestPrecondition<R>?

    init(id: UUID, store: RouterStore<R>, scope: RouterScope<R>) {
        self.id = id
        self.lifecycleToken = store.windowLifecycleTokens[id]
        self.store = store
        self.scope = scope
    }

#if !os(tvOS) && !os(watchOS)
    @Environment(\.openWindow) private var openWindow
#endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                appearedLifetime = lifecycleToken
                appearedRequestPrecondition = scope.combinedExecutionPrecondition(nil)
                guard let lifecycleToken, let appearedRequestPrecondition,
                      appearedRequestPrecondition(store.state) == nil else { return }
                store.sceneRestorationRegistry.finishWindowRestoration(
                    id: id,
                    lifecycleToken: lifecycleToken
                )
            }
            .onDisappear {
                let lifecycleToken = appearedLifetime
                let requestPrecondition = appearedRequestPrecondition
                appearedLifetime = nil
                appearedRequestPrecondition = nil
                guard let lifecycleToken, let requestPrecondition,
                      requestPrecondition(store.state) == nil,
                      let restorationTicket = store.sceneRestorationRegistry
                      .beginWindowRestoration(
                          id: id,
                          lifecycleToken: lifecycleToken
                      ) else {
                    return
                }
                Task { @MainActor in
                    var keepsRestorationReservation = false
                    defer {
                        if !keepsRestorationReservation {
                            store.sceneRestorationRegistry.finishWindowRestoration(
                                id: id,
                                lifecycleToken: lifecycleToken,
                                ticket: restorationTicket
                            )
                        }
                    }

                    guard let outcome = await synchronizeRouterWindowDisappearance(
                        id: id,
                        lifecycleToken: lifecycleToken,
                        store: store,
                        executionPrecondition: requestPrecondition
                    ) else { return }

#if !os(tvOS) && !os(watchOS)
                    guard requestPrecondition(store.state) == nil,
                          shouldRestoreRouterScene(after: outcome),
                          store.sceneRestorationRegistry.isCurrentWindowRestoration(
                              id: id,
                              lifecycleToken: lifecycleToken,
                              ticket: restorationTicket
                          ),
                          store.windowLifecycleTokens[id] == lifecycleToken,
                          let window = store.state.windows.first(where: { $0.id == id }),
                          let scene = R.routerScene(for: window.route),
                          scene.style == .window else { return }
                    keepsRestorationReservation = true
                    openWindow(id: scene.id, value: id)
#endif
                }
            }
    }
}

@MainActor
private struct RouterImmersiveSpaceLifecycleModifier<R: RouterSceneRoute>: ViewModifier {
    let id: String
    let lifecycleToken: UUID?
    let store: RouterStore<R>
    // Retains the observed lifetime slot even when used without a Scene host.
    let scope: RouterScope<R>
    @State private var appearedLifetime: UUID?
    @State private var appearedRequestPrecondition: RouterRequestPrecondition<R>?

#if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
#endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                appearedLifetime = lifecycleToken
                appearedRequestPrecondition = scope.combinedExecutionPrecondition(nil)
                guard let lifecycleToken, let appearedRequestPrecondition,
                      appearedRequestPrecondition(store.state) == nil else { return }
                store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
                    id: id,
                    lifecycleToken: lifecycleToken
                )
            }
            .onDisappear {
                // A body refresh may already contain the replacement's token
                // while the previous native space is still disappearing.
                let lifecycleToken = appearedLifetime
                let requestPrecondition = appearedRequestPrecondition
                appearedLifetime = nil
                appearedRequestPrecondition = nil
                guard let lifecycleToken, let requestPrecondition,
                      requestPrecondition(store.state) == nil,
                      let restorationTicket = store.sceneRestorationRegistry
                      .beginImmersiveSpaceRestoration(
                          id: id,
                          lifecycleToken: lifecycleToken
                      ) else { return }
                Task { @MainActor in
                    defer { store.runtimeDependencies.didFinishImmersiveDisappearance() }
                    var keepsRestorationReservation = false
                    defer {
                        if !keepsRestorationReservation {
                            store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
                                id: id,
                                lifecycleToken: lifecycleToken,
                                ticket: restorationTicket
                            )
                        }
                    }

                    guard let outcome = await synchronizeRouterImmersiveSpaceDisappearance(
                        id: id,
                        lifecycleToken: lifecycleToken,
                        store: store,
                        executionPrecondition: requestPrecondition
                    ) else { return }

#if os(visionOS)
                    guard shouldRestoreRouterScene(after: outcome) else { return }
                    keepsRestorationReservation = await
                        restoreRouterImmersiveSpaceAfterDeferredClosure(
                            id: id,
                            lifecycleToken: lifecycleToken,
                            ticket: restorationTicket,
                            store: store,
                            open: {
                            switch await openImmersiveSpace(id: id) {
                            case .opened: .opened
                            case .userCancelled: .userCancelled
                            case .error: .error
                            @unknown default: .error
                            }
                            },
                            dismiss: { await dismissImmersiveSpace() },
                            executionPrecondition: requestPrecondition
                        )
#endif
                }
            }
    }
}
