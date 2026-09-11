// MARK: - RouterSceneLifecycle.swift
// InnoRouterSwiftUI - native scene lifecycle reconciliation
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import SwiftUI

import InnoRouterCore

@MainActor
package final class RouterSceneRestorationRegistry {
    private struct WindowLifetime: Hashable {
        let id: UUID
        let token: UUID
    }

    private struct ImmersiveSpaceLifetime: Hashable {
        let id: String
        let token: UUID
    }

    private var restoringWindows: [WindowLifetime: UUID] = [:]
    private var restoringImmersiveSpaces: [ImmersiveSpaceLifetime: UUID] = [:]

    package init() {}

    package func beginWindowRestoration(id: UUID, lifecycleToken: UUID) -> UUID? {
        let lifetime = WindowLifetime(id: id, token: lifecycleToken)
        guard restoringWindows[lifetime] == nil else { return nil }
        let ticket = UUID()
        restoringWindows[lifetime] = ticket
        return ticket
    }

    package func isCurrentWindowRestoration(
        id: UUID,
        lifecycleToken: UUID,
        ticket: UUID
    ) -> Bool {
        restoringWindows[WindowLifetime(id: id, token: lifecycleToken)] == ticket
    }

    package func finishWindowRestoration(
        id: UUID,
        lifecycleToken: UUID,
        ticket: UUID? = nil
    ) {
        let lifetime = WindowLifetime(id: id, token: lifecycleToken)
        guard ticket == nil || restoringWindows[lifetime] == ticket else { return }
        restoringWindows[lifetime] = nil
    }

    package func beginImmersiveSpaceRestoration(
        id: String,
        lifecycleToken: UUID
    ) -> UUID? {
        let lifetime = ImmersiveSpaceLifetime(id: id, token: lifecycleToken)
        guard restoringImmersiveSpaces[lifetime] == nil else { return nil }
        let ticket = UUID()
        restoringImmersiveSpaces[lifetime] = ticket
        return ticket
    }

    package func isCurrentImmersiveSpaceRestoration(
        id: String,
        lifecycleToken: UUID,
        ticket: UUID
    ) -> Bool {
        restoringImmersiveSpaces[
            ImmersiveSpaceLifetime(id: id, token: lifecycleToken)
        ] == ticket
    }

    package func finishImmersiveSpaceRestoration(
        id: String,
        lifecycleToken: UUID,
        ticket: UUID? = nil
    ) {
        let lifetime = ImmersiveSpaceLifetime(id: id, token: lifecycleToken)
        guard ticket == nil || restoringImmersiveSpaces[lifetime] == ticket else { return }
        restoringImmersiveSpaces[lifetime] = nil
    }
}

package enum RouterImmersiveSpaceOpenResult: Sendable, Equatable {
    case opened
    case userCancelled
    case error
}

@MainActor
package func restoreRouterImmersiveSpaceAfterDeferredClosure<R: Route>(
    id: String,
    lifecycleToken: UUID,
    ticket: UUID,
    store: RouterStore<R>,
    open: @MainActor @Sendable () async -> RouterImmersiveSpaceOpenResult
) async -> Bool {
    var keepsReservation = false
    defer {
        if !keepsReservation {
            store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
                id: id,
                lifecycleToken: lifecycleToken,
                ticket: ticket
            )
        }
    }

    guard store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(
        id: id,
        lifecycleToken: lifecycleToken,
        ticket: ticket
    ), store.state.immersiveSpace?.id == id,
       store.immersiveSpaceLifecycleToken == lifecycleToken else {
        return false
    }

    let result = await open()
    guard store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(
        id: id,
        lifecycleToken: lifecycleToken,
        ticket: ticket
    ), store.state.immersiveSpace?.id == id,
       store.immersiveSpaceLifecycleToken == lifecycleToken else {
        return false
    }

    switch result {
    case .opened:
        keepsReservation = true
        return true
    case .userCancelled, .error:
        _ = await store.reconcileSceneSystemFailure(
            .dismissImmersiveSpace,
            executionPrecondition: { [weak store] state in
                guard let store,
                      state.immersiveSpace?.id == id,
                      store.immersiveSpaceLifecycleToken == lifecycleToken else {
                    return .cancelled
                }
                return nil
            }
        )
        return false
    }
}

public extension View {
    /// Reconciles an interactively closed value-based window with its store.
    ///
    /// Attach this to the content of the matching
    /// `WindowGroup(id:for: UUID.self)`. A system-originated close removes only
    /// this window ID. If a router policy rejects the close while the same
    /// window remains authoritative, the native window is reopened.
    @MainActor
    func routerWindowLifecycle<R: RouterSceneRoute>(
        _ id: UUID,
        store: RouterStore<R>
    ) -> some View {
        modifier(RouterWindowLifecycleModifier(id: id, store: store))
    }

    /// Reconciles an interactively dismissed immersive space with its store.
    ///
    /// Attach this to the matching `ImmersiveSpace` content. Rejected system
    /// dismissal is reopened only while the same immersive-space lifetime
    /// remains authoritative in canonical state.
    @MainActor
    func routerImmersiveSpaceLifecycle<R: RouterSceneRoute>(
        _ id: String,
        store: RouterStore<R>
    ) -> some View {
        modifier(RouterImmersiveSpaceLifecycleModifier(
            id: id,
            lifecycleToken: store.state.immersiveSpace?.id == id
                ? store.immersiveSpaceLifecycleToken
                : nil,
            store: store
        ))
    }
}

@MainActor
private struct RouterWindowLifecycleModifier<R: RouterSceneRoute>: ViewModifier {
    let id: UUID
    let lifecycleToken: UUID?
    let store: RouterStore<R>

    init(id: UUID, store: RouterStore<R>) {
        self.id = id
        self.lifecycleToken = store.windowLifecycleTokens[id]
        self.store = store
    }

#if !os(tvOS) && !os(watchOS)
    @Environment(\.openWindow) private var openWindow
#endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let lifecycleToken else { return }
                store.sceneRestorationRegistry.finishWindowRestoration(
                    id: id,
                    lifecycleToken: lifecycleToken
                )
            }
            .onDisappear {
                guard let lifecycleToken,
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
                        store: store
                    ) else { return }

#if !os(tvOS) && !os(watchOS)
                    guard shouldRestoreRouterScene(after: outcome),
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

#if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
#endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let lifecycleToken else { return }
                store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
                    id: id,
                    lifecycleToken: lifecycleToken
                )
            }
            .onDisappear {
                guard let lifecycleToken,
                      let restorationTicket = store.sceneRestorationRegistry
                      .beginImmersiveSpaceRestoration(
                          id: id,
                          lifecycleToken: lifecycleToken
                      ) else { return }
                Task { @MainActor in
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
                        store: store
                    ) else { return }

#if os(visionOS)
                    guard shouldRestoreRouterScene(after: outcome) else { return }
                    keepsRestorationReservation = await
                        restoreRouterImmersiveSpaceAfterDeferredClosure(
                            id: id,
                            lifecycleToken: lifecycleToken,
                            ticket: restorationTicket,
                            store: store
                        ) {
                            switch await openImmersiveSpace(id: id) {
                            case .opened: .opened
                            case .userCancelled: .userCancelled
                            case .error: .error
                            @unknown default: .error
                            }
                        }
#endif
                }
            }
    }
}

@MainActor
package func shouldRestoreRouterScene<R: Route>(
    after outcome: RouterOutcome<R>
) -> Bool {
    switch outcome {
    case .deferred, .rejected:
        true
    case .applied, .unchanged:
        false
    }
}

@MainActor
package func synchronizeRouterWindowDisappearance<R: Route>(
    id: UUID,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard let lifecycleToken = store.windowLifecycleTokens[id] else {
        return nil
    }
    return await synchronizeRouterWindowDisappearance(
        id: id,
        lifecycleToken: lifecycleToken,
        store: store
    )
}

@MainActor
package func synchronizeRouterWindowDisappearance<R: Route>(
    id: UUID,
    lifecycleToken: UUID,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard store.state.windows.contains(where: { $0.id == id }),
          store.windowLifecycleTokens[id] == lifecycleToken else { return nil }
    return await store.perform(
        .dismissWindow(id),
        context: .init(source: .system),
        expectedRevision: nil,
        bypassesPolicies: false,
        executionPrecondition: { [weak store] state in
            guard state.windows.contains(where: { $0.id == id }) else {
                return .mutation(.windowNotFound(id))
            }
            guard store?.windowLifecycleTokens[id] == lifecycleToken else {
                return .cancelled
            }
            return nil
        }
    )
}

@MainActor
package func synchronizeRouterImmersiveSpaceDisappearance<R: Route>(
    id: String,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard store.state.immersiveSpace?.id == id,
          let lifecycleToken = store.immersiveSpaceLifecycleToken else {
        return nil
    }
    return await synchronizeRouterImmersiveSpaceDisappearance(
        id: id,
        lifecycleToken: lifecycleToken,
        store: store
    )
}

@MainActor
package func synchronizeRouterImmersiveSpaceDisappearance<R: Route>(
    id: String,
    lifecycleToken: UUID,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard store.state.immersiveSpace?.id == id,
          store.immersiveSpaceLifecycleToken == lifecycleToken else {
        return nil
    }
    return await store.perform(
        .dismissImmersiveSpace,
        context: .init(source: .system),
        expectedRevision: nil,
        bypassesPolicies: false,
        executionPrecondition: { [weak store] state in
            guard state.immersiveSpace?.id == id else {
                return .mutation(.immersiveSpaceNotFound(id))
            }
            guard store?.immersiveSpaceLifecycleToken == lifecycleToken else {
                return .cancelled
            }
            return nil
        }
    )
}
