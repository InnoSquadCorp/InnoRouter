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
    let store: RouterStore<R>

#if !os(tvOS) && !os(watchOS)
    @Environment(\.openWindow) private var openWindow
#endif

    func body(content: Content) -> some View {
        content.onDisappear {
            Task { @MainActor in
                guard let outcome = await synchronizeRouterWindowDisappearance(
                    id: id,
                    store: store
                ) else { return }

#if !os(tvOS) && !os(watchOS)
                guard case .rejected = outcome,
                      let window = store.state.windows.first(where: { $0.id == id }),
                      let scene = R.routerScene(for: window.route),
                      scene.style == .window else { return }
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
        content.onDisappear {
            Task { @MainActor in
                guard let lifecycleToken else { return }
                guard let outcome = await synchronizeRouterImmersiveSpaceDisappearance(
                    id: id,
                    lifecycleToken: lifecycleToken,
                    store: store
                ) else { return }

#if os(visionOS)
                guard case .rejected = outcome,
                      store.state.immersiveSpace?.id == id,
                      store.immersiveSpaceLifecycleToken == lifecycleToken else { return }
                _ = await openImmersiveSpace(id: id)
#endif
            }
        }
    }
}

@MainActor
package func synchronizeRouterWindowDisappearance<R: Route>(
    id: UUID,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard store.state.windows.contains(where: { $0.id == id }) else {
        return nil
    }
    return await store.perform(
        .dismissWindow(id),
        context: .init(source: .system)
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
            guard state.immersiveSpace?.id == id,
                  store?.immersiveSpaceLifecycleToken == lifecycleToken else {
                return .mutation(.immersiveSpaceNotFound(id))
            }
            return nil
        }
    )
}
