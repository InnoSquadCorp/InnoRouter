// MARK: - RouterSceneHost.swift
// InnoRouterSwiftUI - scene-local native navigation hosts
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import SwiftUI

import InnoRouterCore

/// A macro-generated, type-safe request for one regular-window scene.
public struct RouterWindowRequest<R: Route>: Hashable, Sendable {
    public let route: R
    public let sceneID: String

    public init(route: R, sceneID: String) {
        self.route = route
        self.sceneID = sceneID
    }
}

/// A macro-generated, type-safe request for one immersive-space scene.
public struct RouterImmersiveSpaceRequest<R: Route>: Hashable, Sendable {
    public let route: R
    public let sceneID: String

    public init(route: R, sceneID: String) {
        self.route = route
        self.sceneID = sceneID
    }
}

/// Hosts the independent stack and presentations of one exact regular window.
///
/// Use this as the content of the matching value-based
/// `WindowGroup(id:for: UUID.self)`. The scene route is rendered as the native
/// stack root while the window's ``RouterNode`` owns every pushed destination
/// and presentation above it. The default explicitly requires a stack catalog
/// entry. Supply a fixed descriptor for a container scene; a mismatch renders
/// typed recovery without changing canonical state.
@MainActor
public struct RouterWindowHost<R: DestinationRoute & RouterSceneRoute>: View {
    private let id: UUID
    private let store: RouterStore<R>
    private let rendering: RouterHostViewDescriptor<R>?
    private let presentations: RouterPresentationViewCatalog<R>

#if !os(tvOS) && !os(watchOS)
    @Environment(\.dismissWindow) private var dismissWindow
#endif

    public init(
        id: UUID, store: RouterStore<R>, rendering: RouterHostViewDescriptor<R>? = nil,
        presentations: RouterPresentationViewCatalog<R> = .stack
    ) {
        self.id = id
        self.store = store
        self.rendering = rendering
        self.presentations = presentations
    }

    /// An absent scene follows native close repair; a live scene reports its
    /// fixed renderer mismatch without changing the Store or opening a window.
    public var validationFailure: RouterHostValidationFailure? {
        routerSceneHostValidationFailure(store: store, path: .window(id), rendering: rendering, presentations: presentations)
    }

    @ViewBuilder
    public var body: some View {
        switch routerSceneHostScope(store: store, path: .window(id)) {
        case .failure(let failure):
            RouterHostRecoveryView(failure: failure)
        case .success(let scope):
            sceneContent(scope)
        }
    }

    @ViewBuilder
    private func sceneContent(_ scope: RouterScope<R>?) -> some View {
        if let scope, let rootRoute = scope.observedSceneRootRoute {
            RouterValidatedHostSurface(
                store: store, shape: rendering?.shape ?? .stack,
                rootDeclarations: rendering?.rootDeclarations ?? [],
                presentations: presentations, path: scope.path
            ) { child in
                if let rendering {
                    rendering.render(child)
                } else {
                    RouterStoreStackSurface(
                        scope: child, destination: R.destination(for:),
                        root: { R.destination(for: rootRoute) }
                    ).routerAuthority(child, for: R.self)
                }
            }
            .routerWindowLifecycle(id, store: store)
        } else {
            // A restored native window can finish opening after the driver has
            // already dismissed its canonical value. Repair from this window's
            // own environment once its empty host is mounted as well.
            Color.clear
                .task {
#if !os(tvOS) && !os(watchOS)
                    guard case .success(nil) = routerSceneHostScope(store: store, path: .window(id)) else { return }
                    dismissWindow()
#endif
                }
        }
    }
}

/// Hosts the independent stack and presentations of the active immersive space.
@MainActor
public struct RouterImmersiveSpaceHost<R: DestinationRoute & RouterSceneRoute>: View {
    @Environment(\.routerImmersiveActivationBinding) private var activationBinding
    private let id: String
    private let store: RouterStore<R>
    private let rendering: RouterHostViewDescriptor<R>?
    private let presentations: RouterPresentationViewCatalog<R>

    public init(
        id: String, store: RouterStore<R>, rendering: RouterHostViewDescriptor<R>? = nil,
        presentations: RouterPresentationViewCatalog<R> = .stack
    ) {
        self.id = id
        self.store = store
        self.rendering = rendering
        self.presentations = presentations
    }

    public var validationFailure: RouterHostValidationFailure? {
        routerSceneHostValidationFailure(store: store, path: .immersiveSpace(id), rendering: rendering, presentations: presentations)
    }

    @ViewBuilder
    public var body: some View {
        switch routerSceneHostScope(store: store, path: .immersiveSpace(id)) {
        case .failure(let failure):
            RouterHostRecoveryView(failure: failure)
        case .success(let scope):
            let admitted = !activationBinding.isAttributed
                || activationBinding.activation.map({ store.canRenderAttributedImmersiveSpace($0) }) == true
            // Keep the same native boundary in the success branch when content
            // loses authority. A structural branch change would manufacture a
            // native disappearance during the paired repair/recovery commits.
            sceneContent(admitted ? scope : nil)
        }
    }

    @ViewBuilder
    private func sceneContent(_ scope: RouterScope<R>?) -> some View {
        // Keep the native lifetime boundary mounted while canonical content is
        // temporarily empty. Removing the inner stack is not a native close.
        ZStack {
            if let scope, let rootRoute = scope.observedSceneRootRoute {
                RouterValidatedHostSurface(
                    store: store, shape: rendering?.shape ?? .stack,
                    rootDeclarations: rendering?.rootDeclarations ?? [],
                    presentations: presentations, path: scope.path
                ) { child in
                    if let rendering {
                        rendering.render(child)
                    } else {
                        RouterStoreStackSurface(
                            scope: child, destination: R.destination(for:),
                            root: { R.destination(for: rootRoute) }
                        ).routerAuthority(child, for: R.self)
                    }
                }
            }
        }
        .modifier(RouterImmersiveHostLifecycle(
            id: id, store: store, binding: activationBinding
        ))
    }
}

private struct RouterImmersiveHostLifecycle<R: RouterSceneRoute>: ViewModifier {
    let id: String
    let store: RouterStore<R>
    let binding: RouterImmersiveActivationBinding

    @ViewBuilder
    func body(content: Content) -> some View {
        if binding.isAttributed {
            content.routerAttributedImmersiveSpaceLifecycle(id, store: store, binding: binding)
        } else {
            content.routerImmersiveSpaceLifecycle(id, store: store)
        }
    }
}

@MainActor
private func routerSceneHostValidationFailure<R: DestinationRoute>(
    store: RouterStore<R>, path: RouterScopePath, rendering: RouterHostViewDescriptor<R>?,
    presentations: RouterPresentationViewCatalog<R>
) -> RouterHostValidationFailure? {
    do {
        guard try store.admittedSceneHostScope(at: path) != nil else { return nil }
        try store.validateHostRenderer(shape: rendering?.shape ?? .stack, at: path,
                                      rootDeclarations: rendering?.rootDeclarations ?? [])
        try presentations.validate(for: store)
        return nil
    } catch {
        return error
    }
}

@MainActor
private func routerSceneHostScope<R: Route>(
    store: RouterStore<R>, path: RouterScopePath
) -> Result<RouterScope<R>?, RouterHostValidationFailure> {
    do { return .success(try store.admittedSceneHostScope(at: path)) }
    catch { return .failure(error) }
}
