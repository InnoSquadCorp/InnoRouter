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
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == operationGeneration {
            tail = nil
        }
    }
}

private struct RouterSceneReconciliationID: Hashable {
    let store: ObjectIdentifier
    let revision: UInt64
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
    @State private var previousWindowLifetimes: [UUID: UUID] = [:]
    @State private var previousWindowStoreIdentities: [UUID: ObjectIdentifier] = [:]
    @State private var previousImmersiveSpace: RouterImmersiveSpace<R>?
    @State private var previousImmersiveSpaceLifetime: UUID?
    @State private var previousStoreIdentity: ObjectIdentifier?
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
            .task(id: RouterSceneReconciliationID(
                store: ObjectIdentifier(store),
                revision: store.revision
            )) {
                let reconciliationID = RouterSceneReconciliationID(
                    store: ObjectIdentifier(store),
                    revision: store.revision
                )
                let state = store.state
                let windowLifetimes = store.windowLifecycleTokens
                let immersiveSpaceLifetime = store.immersiveSpaceLifecycleToken
                await reconciliationQueue.enqueue {
                    await reconcile(
                        with: state,
                        windowLifetimes: windowLifetimes,
                        immersiveSpaceLifetime: immersiveSpaceLifetime,
                        expected: reconciliationID
                    )
                }
            }
    }

    private func reconcile(
        with state: RouterState<R>,
        windowLifetimes: [UUID: UUID],
        immersiveSpaceLifetime: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async {
        guard isCurrent(reconciliationID) else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previousWindows.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.id, $0) })
        let currentStoreIdentity = ObjectIdentifier(store)

        for window in previousWindows where !sameNativeWindowIdentity(
            window,
            currentByID[window.id],
            previousLifetime: previousWindowLifetimes[window.id],
            currentLifetime: windowLifetimes[window.id],
            currentStoreIdentity: currentStoreIdentity
        ) {
            guard isCurrent(reconciliationID) else { return }
            dismiss(window)
            previousWindows.removeAll { $0.id == window.id }
            previousWindowLifetimes[window.id] = nil
            previousWindowStoreIdentities[window.id] = nil
        }
        for window in state.windows where !sameNativeWindowIdentity(
            previousByID[window.id],
            window,
            previousLifetime: previousWindowLifetimes[window.id],
            currentLifetime: windowLifetimes[window.id],
            currentStoreIdentity: currentStoreIdentity
        ) {
            guard await open(
                window,
                lifecycleToken: windowLifetimes[window.id],
                expected: reconciliationID
            ) else { return }
        }

        if !sameNativeIdentity(
            previousImmersiveSpace,
            state.immersiveSpace,
            previousLifetime: previousImmersiveSpaceLifetime,
            currentLifetime: immersiveSpaceLifetime,
            currentStoreIdentity: currentStoreIdentity
        ) {
            guard await reconcileImmersiveSpace(
                from: previousImmersiveSpace,
                to: state.immersiveSpace,
                currentLifetime: immersiveSpaceLifetime,
                expected: reconciliationID
            ) else { return }
        }

        guard isCurrent(reconciliationID) else { return }
        previousWindows = state.windows
        previousWindowLifetimes = windowLifetimes
        previousWindowStoreIdentities = Dictionary(
            uniqueKeysWithValues: state.windows.map { ($0.id, currentStoreIdentity) }
        )
        previousImmersiveSpace = state.immersiveSpace
        previousImmersiveSpaceLifetime = immersiveSpaceLifetime
        previousStoreIdentity = currentStoreIdentity
    }

    private func sameNativeWindowIdentity(
        _ lhs: RouterWindow<R>?,
        _ rhs: RouterWindow<R>?,
        previousLifetime: UUID?,
        currentLifetime: UUID?,
        currentStoreIdentity: ObjectIdentifier
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return previousWindowStoreIdentities[lhs.id] == currentStoreIdentity
            && lhs.id == rhs.id
            && lhs.route == rhs.route
            && previousLifetime != nil
            && previousLifetime == currentLifetime
    }

    private func sameNativeIdentity(
        _ lhs: RouterImmersiveSpace<R>?,
        _ rhs: RouterImmersiveSpace<R>?,
        previousLifetime: UUID?,
        currentLifetime: UUID?,
        currentStoreIdentity: ObjectIdentifier
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case (.some(let lhs), .some(let rhs)):
            previousStoreIdentity == currentStoreIdentity
                && lhs.id == rhs.id
                && lhs.route == rhs.route
                && previousLifetime != nil
                && previousLifetime == currentLifetime
        case (.some, nil), (nil, .some):
            false
        }
    }

    private func open(
        _ window: RouterWindow<R>,
        lifecycleToken: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async -> Bool {
        guard let scene = catalog.descriptor(for: window.route), scene.style == .window else {
            onEvent(.unsupported(route: window.route, style: .window))
            await rollback(
                window,
                lifecycleToken: lifecycleToken,
                expected: reconciliationID
            )
            return false
        }
#if !os(tvOS) && !os(watchOS)
        guard isCurrent(reconciliationID) else { return false }
        openWindow(id: scene.id, value: window.id)
        previousWindows.removeAll { $0.id == window.id }
        previousWindows.append(window)
        previousWindowLifetimes[window.id] = lifecycleToken
        previousWindowStoreIdentities[window.id] = ObjectIdentifier(store)
        onEvent(.openedWindow(window, sceneID: scene.id))
        return true
#else
        onEvent(.unsupported(route: window.route, style: .window))
        await rollback(
            window,
            lifecycleToken: lifecycleToken,
            expected: reconciliationID
        )
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
        currentLifetime: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async -> Bool {
        await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue {
            await reconcileImmersiveSpaceEffect(
                from: previous,
                to: current,
                currentLifetime: currentLifetime,
                expected: reconciliationID
            )
        }
    }

    private func reconcileImmersiveSpaceEffect(
        from previous: RouterImmersiveSpace<R>?,
        to current: RouterImmersiveSpace<R>?,
        currentLifetime: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async -> Bool {
#if os(visionOS)
        if let previous {
            await dismissImmersiveSpace()
            previousImmersiveSpace = nil
            onEvent(.dismissedImmersiveSpace(previous))
            guard isCurrent(reconciliationID) else { return false }
        }
        guard let current else { return true }
        guard let scene = catalog.descriptor(for: current.route),
              scene.style == .immersiveSpace,
              scene.id == current.id else {
            onEvent(.unsupported(route: current.route, style: .immersiveSpace))
            await rollback(
                current,
                lifecycleToken: currentLifetime,
                expected: reconciliationID
            )
            return false
        }
        let result = await openImmersiveSpace(id: scene.id)
        guard isCurrent(reconciliationID) else {
            if result == .opened {
                await dismissImmersiveSpace()
            }
            return false
        }
        if result == .opened {
            previousImmersiveSpace = current
            previousImmersiveSpaceLifetime = currentLifetime
            onEvent(.openedImmersiveSpace(current))
            return true
        } else {
            previousImmersiveSpace = nil
            onEvent(.immersiveOpenFailed(current))
            await rollback(
                current,
                lifecycleToken: currentLifetime,
                expected: reconciliationID
            )
            return false
        }
#else
        if let previous {
            onEvent(.unsupported(route: previous.route, style: .immersiveSpace))
        }
        if let current {
            onEvent(.unsupported(route: current.route, style: .immersiveSpace))
            await rollback(
                current,
                lifecycleToken: currentLifetime,
                expected: reconciliationID
            )
            return false
        }
        return true
#endif
    }

    private func rollback(
        _ window: RouterWindow<R>,
        lifecycleToken: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async {
        guard isCurrent(reconciliationID),
              store.state.windows.contains(where: { $0 == window }),
              let lifecycleToken,
              store.windowLifecycleTokens[window.id] == lifecycleToken else { return }
        _ = await store.reconcileSceneSystemFailure(
            .dismissWindow(window.id),
            expectedRevision: reconciliationID.revision,
            executionPrecondition: { [weak store] state in
                guard state.windows.contains(where: { $0 == window }),
                      store?.windowLifecycleTokens[window.id] == lifecycleToken else {
                    return .cancelled
                }
                return nil
            }
        )
    }

    private func rollback(
        _ space: RouterImmersiveSpace<R>,
        lifecycleToken: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async {
        guard isCurrent(reconciliationID),
              store.state.immersiveSpace == space,
              let lifecycleToken,
              store.immersiveSpaceLifecycleToken == lifecycleToken else { return }
        _ = await store.reconcileSceneSystemFailure(
            .dismissImmersiveSpace,
            expectedRevision: reconciliationID.revision,
            executionPrecondition: { [weak store] state in
                guard state.immersiveSpace == space,
                      store?.immersiveSpaceLifecycleToken == lifecycleToken else {
                    return .cancelled
                }
                return nil
            }
        )
    }

    private func isCurrent(_ expected: RouterSceneReconciliationID) -> Bool {
        !Task.isCancelled
            && ObjectIdentifier(store) == expected.store
            && store.revision == expected.revision
    }
}
