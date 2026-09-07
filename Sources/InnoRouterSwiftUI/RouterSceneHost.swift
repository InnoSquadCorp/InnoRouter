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
/// and presentation above it.
@MainActor
public struct RouterWindowHost<R: DestinationRoute & RouterSceneRoute>: View {
    private let id: UUID
    private let store: RouterStore<R>
    private let scope: RouterScope<R>

    public init(id: UUID, store: RouterStore<R>) {
        self.id = id
        self.store = store
        self.scope = store.scope(at: .window(id))
    }

    @ViewBuilder
    public var body: some View {
        if let rootRoute = scope.observedSceneRootRoute {
            RouterStoreStackSurface(
                scope: scope,
                destination: R.destination(for:),
                root: { R.destination(for: rootRoute) }
            )
            .routerAuthority(scope, for: R.self)
            .routerWindowLifecycle(id, store: store)
        }
    }
}

/// Hosts the independent stack and presentations of the active immersive space.
@MainActor
public struct RouterImmersiveSpaceHost<R: DestinationRoute & RouterSceneRoute>: View {
    private let id: String
    private let store: RouterStore<R>
    private let scope: RouterScope<R>

    public init(id: String, store: RouterStore<R>) {
        self.id = id
        self.store = store
        self.scope = store.scope(at: .immersiveSpace(id))
    }

    @ViewBuilder
    public var body: some View {
        if let rootRoute = scope.observedSceneRootRoute {
            RouterStoreStackSurface(
                scope: scope,
                destination: R.destination(for:),
                root: { R.destination(for: rootRoute) }
            )
            .routerAuthority(scope, for: R.self)
            .routerImmersiveSpaceLifecycle(id, store: store)
        }
    }
}
