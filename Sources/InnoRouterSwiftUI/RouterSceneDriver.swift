// MARK: - RouterSceneDriver.swift
// InnoRouterSwiftUI - canonical RouterState to SwiftUI scene effects
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouterCore

/// A system scene surface addressable from one macro-first route.
public enum RouterSceneStyle: String, Hashable, Sendable, Codable {
    case window
    case immersiveSpace
}

/// Stable metadata connecting a route value to a SwiftUI scene identifier.
public struct RouterSceneDescriptor<R: Route>: Hashable, Sendable, Identifiable {
    public let route: R
    public let id: String
    public let style: RouterSceneStyle

    public init(route: R, id: String, style: RouterSceneStyle) {
        self.route = route
        self.id = id
        self.style = style
    }
}

/// Type-erased scene identity used by store-level catalog validation.
package struct RouterSceneMetadata: Hashable, Sendable {
    package let id: String
    package let style: RouterSceneStyle

    package init(id: String, style: RouterSceneStyle) {
        self.id = id
        self.style = style
    }
}

/// Structural failures in an application-authored scene catalog.
public enum RouterSceneCatalogError: Error, Hashable, Sendable {
    case empty
    case emptyIdentifier
    case duplicateIdentifier(String)
    case duplicateRoute
}

/// A validated scene catalog for advanced manual conformances.
///
/// Macro-generated catalogs are checked at expansion time. Manual catalogs can
/// use this throwing value before constructing a scene driver.
public struct RouterSceneCatalog<R: RouterSceneRoute>: Sendable {
    public let descriptors: [RouterSceneDescriptor<R>]

    public init(_ descriptors: [RouterSceneDescriptor<R>]) throws {
        guard !descriptors.isEmpty else { throw RouterSceneCatalogError.empty }
        guard !descriptors.contains(where: {
            !$0.id.contains(where: { !$0.isWhitespace })
        }) else {
            throw RouterSceneCatalogError.emptyIdentifier
        }
        var identifiers: Set<String> = []
        for descriptor in descriptors where !identifiers.insert(descriptor.id).inserted {
            throw RouterSceneCatalogError.duplicateIdentifier(descriptor.id)
        }
        guard Set(descriptors.map(\.route)).count == descriptors.count else {
            throw RouterSceneCatalogError.duplicateRoute
        }
        self.descriptors = descriptors
    }

    public func descriptor(for route: R) -> RouterSceneDescriptor<R>? {
        descriptors.first { $0.route == route }
    }
}

/// A route whose `@Scene` cases form a stable window and immersive catalog.
public protocol RouterSceneRoute: Route {
    static var routerScenes: [RouterSceneDescriptor<Self>] { get }
}

public extension RouterSceneRoute {
    static func routerScene(for route: Self) -> RouterSceneDescriptor<Self>? {
        routerScenes.first { $0.route == route }
    }

    package var routerSceneMetadata: RouterSceneMetadata? {
        Self.routerScene(for: self).map {
            RouterSceneMetadata(id: $0.id, style: $0.style)
        }
    }
}

/// Side-effect milestones emitted by ``RouterSceneDriver``.
public enum RouterSceneDriverEvent<R: Route>: Sendable, Equatable {
    case openedWindow(RouterWindow<R>, sceneID: String)
    case dismissedWindow(RouterWindow<R>, sceneID: String)
    case openedImmersiveSpace(RouterImmersiveSpace<R>)
    case dismissedImmersiveSpace(RouterImmersiveSpace<R>)
    case unsupported(route: R, style: RouterSceneStyle)
    case immersiveOpenFailed(RouterImmersiveSpace<R>)
}

@MainActor
private final class RouterSceneReconciliationQueue {
    private var generation: UInt64 = 0
    private var tail: Task<Void, Never>?

    func enqueue(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        generation &+= 1
        let operationGeneration = generation
        let predecessor = tail
        let task = Task { @MainActor in
            await predecessor?.value
            await operation()
        }
        tail = task
        await task.value
        if generation == operationGeneration {
            tail = nil
        }
    }
}

/// Executes the window and immersive-space differences in ``RouterState``.
///
/// The store remains the only mutable authority. This view is the explicit
/// SwiftUI effect boundary that translates committed state into environment
/// actions. Applications declare regular windows with
/// `WindowGroup(id:for: UUID.self)` so the router's exact window identity is
/// preserved, and declare matching `ImmersiveSpace(id:)` scenes from the
/// generated route catalog.
@MainActor
public struct RouterSceneDriver<R: RouterSceneRoute, Content: View>: View {
    private let store: RouterStore<R>
    private let catalog: RouterSceneCatalog<R>
    private let onEvent: @MainActor @Sendable (RouterSceneDriverEvent<R>) -> Void
    private let content: () -> Content

    @State private var previousWindows: [RouterWindow<R>] = []
    @State private var previousImmersiveSpace: RouterImmersiveSpace<R>?
    @State private var reconciliationQueue = RouterSceneReconciliationQueue()

#if !os(tvOS) && !os(watchOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
#endif
#if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
#endif

    public init(
        store: RouterStore<R>,
        onEvent: @escaping @MainActor @Sendable (RouterSceneDriverEvent<R>) -> Void = { _ in },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.store = store
        do {
            self.catalog = try RouterSceneCatalog(R.routerScenes)
        } catch {
            preconditionFailure("@Router generated an invalid scene catalog: \(error)")
        }
        self.onEvent = onEvent
        self.content = content
    }

    /// Creates a driver from an explicitly validated manual scene catalog.
    public init(
        store: RouterStore<R>,
        catalog: RouterSceneCatalog<R>,
        onEvent: @escaping @MainActor @Sendable (RouterSceneDriverEvent<R>) -> Void = { _ in },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.store = store
        self.catalog = catalog
        self.onEvent = onEvent
        self.content = content
    }

    public var body: some View {
        content()
            .task(id: store.revision) {
                let revision = store.revision
                let state = store.state
                await reconciliationQueue.enqueue {
                    await reconcile(with: state, expectedRevision: revision)
                }
            }
    }

    private func reconcile(
        with state: RouterState<R>,
        expectedRevision: UInt64
    ) async {
        guard isCurrent(expectedRevision) else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previousWindows.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.id, $0) })

        for window in previousWindows where currentByID[window.id] == nil {
            guard isCurrent(expectedRevision) else { return }
            dismiss(window)
            previousWindows.removeAll { $0.id == window.id }
        }
        for window in state.windows where previousByID[window.id] == nil {
            guard await open(window, expectedRevision: expectedRevision) else { return }
        }

        if !sameNativeIdentity(previousImmersiveSpace, state.immersiveSpace) {
            guard await reconcileImmersiveSpace(
                from: previousImmersiveSpace,
                to: state.immersiveSpace,
                expectedRevision: expectedRevision
            ) else { return }
        }

        guard isCurrent(expectedRevision) else { return }
        previousWindows = state.windows
        previousImmersiveSpace = state.immersiveSpace
    }

    private func sameNativeIdentity(
        _ lhs: RouterImmersiveSpace<R>?,
        _ rhs: RouterImmersiveSpace<R>?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case (.some(let lhs), .some(let rhs)):
            lhs.id == rhs.id && lhs.route == rhs.route
        case (.some, nil), (nil, .some):
            false
        }
    }

    private func open(
        _ window: RouterWindow<R>,
        expectedRevision: UInt64
    ) async -> Bool {
        guard let scene = catalog.descriptor(for: window.route), scene.style == .window else {
            onEvent(.unsupported(route: window.route, style: .window))
            await rollback(window, expectedRevision: expectedRevision)
            return false
        }
#if !os(tvOS) && !os(watchOS)
        guard isCurrent(expectedRevision) else { return false }
        openWindow(id: scene.id, value: window.id)
        previousWindows.removeAll { $0.id == window.id }
        previousWindows.append(window)
        onEvent(.openedWindow(window, sceneID: scene.id))
        return true
#else
        onEvent(.unsupported(route: window.route, style: .window))
        await rollback(window, expectedRevision: expectedRevision)
        return false
#endif
    }

    private func dismiss(_ window: RouterWindow<R>) {
        guard let scene = catalog.descriptor(for: window.route), scene.style == .window else {
            onEvent(.unsupported(route: window.route, style: .window))
            return
        }
#if !os(tvOS) && !os(watchOS)
        dismissWindow(id: scene.id, value: window.id)
        onEvent(.dismissedWindow(window, sceneID: scene.id))
#else
        onEvent(.unsupported(route: window.route, style: .window))
#endif
    }

    private func reconcileImmersiveSpace(
        from previous: RouterImmersiveSpace<R>?,
        to current: RouterImmersiveSpace<R>?,
        expectedRevision: UInt64
    ) async -> Bool {
#if os(visionOS)
        if let previous {
            await dismissImmersiveSpace()
            previousImmersiveSpace = nil
            onEvent(.dismissedImmersiveSpace(previous))
            guard isCurrent(expectedRevision) else { return false }
        }
        guard let current else { return true }
        guard let scene = catalog.descriptor(for: current.route),
              scene.style == .immersiveSpace,
              scene.id == current.id else {
            onEvent(.unsupported(route: current.route, style: .immersiveSpace))
            await rollback(current, expectedRevision: expectedRevision)
            return false
        }
        let result = await openImmersiveSpace(id: scene.id)
        if result == .opened {
            previousImmersiveSpace = current
            onEvent(.openedImmersiveSpace(current))
            return isCurrent(expectedRevision)
        } else {
            previousImmersiveSpace = nil
            onEvent(.immersiveOpenFailed(current))
            await rollback(current, expectedRevision: expectedRevision)
            return false
        }
#else
        if let previous {
            onEvent(.unsupported(route: previous.route, style: .immersiveSpace))
        }
        if let current {
            onEvent(.unsupported(route: current.route, style: .immersiveSpace))
            await rollback(current, expectedRevision: expectedRevision)
            return false
        }
        return true
#endif
    }

    private func rollback(
        _ window: RouterWindow<R>,
        expectedRevision: UInt64
    ) async {
        guard isCurrent(expectedRevision),
              store.state.windows.contains(where: { $0 == window }) else { return }
        _ = await store.reconcileSceneSystemFailure(
            .dismissWindow(window.id),
            expectedRevision: expectedRevision
        )
    }

    private func rollback(
        _ space: RouterImmersiveSpace<R>,
        expectedRevision: UInt64
    ) async {
        guard isCurrent(expectedRevision),
              store.state.immersiveSpace == space else { return }
        _ = await store.reconcileSceneSystemFailure(
            .dismissImmersiveSpace,
            expectedRevision: expectedRevision
        )
    }

    private func isCurrent(_ expectedRevision: UInt64) -> Bool {
        !Task.isCancelled && store.revision == expectedRevision
    }
}
