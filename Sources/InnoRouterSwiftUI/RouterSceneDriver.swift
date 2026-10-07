// MARK: - RouterSceneDriver.swift
// InnoRouterSwiftUI - canonical RouterState to SwiftUI scene effects
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouterCore

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
    let immersiveDismissalEpoch: UUID?
}

/// Executes the window and immersive-space differences in ``RouterState``.
///
/// The store remains the only mutable authority. This view is the explicit
/// SwiftUI effect boundary that translates committed state into environment
/// actions. Applications declare regular windows with
/// `WindowGroup(id:for: UUID.self)` so the router's exact window identity is
/// preserved. On visionOS, declare RouterImmersiveSpaceScene from the generated
/// route catalog to retain native open-attempt identity. Id-only ImmersiveSpace
/// declarations remain supported without recovery of unattributed callbacks.
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
    @State private var immersiveActionsOwner = UUID()
    @State private var registeredRestorationRegistry: RouterSceneRestorationRegistry?

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
            .onAppear { registerImmersiveActions() }
            .onChange(of: ObjectIdentifier(store)) { _, _ in registerImmersiveActions() }
            .onDisappear {
                registeredRestorationRegistry?.removeImmersiveActions(owner: immersiveActionsOwner)
                registeredRestorationRegistry = nil
            }
            .task(id: RouterSceneReconciliationID(
                store: ObjectIdentifier(store),
                revision: store.revision,
                immersiveDismissalEpoch: store.immersiveDismissalEpoch
            )) {
                // SwiftUI may start this task before onAppear/onChange, including
                // when a new Store replaces the old one at the same revision.
                registerImmersiveActions()
                let reconciliationID = RouterSceneReconciliationID(
                    store: ObjectIdentifier(store),
                    revision: store.revision,
                    immersiveDismissalEpoch: store.immersiveDismissalEpoch
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

    private func registerImmersiveActions() {
#if os(visionOS)
        let registry = store.sceneRestorationRegistry
        store.prepareAttributedImmersiveDriver(owner: immersiveActionsOwner)
        if registeredRestorationRegistry !== registry {
            registeredRestorationRegistry?.removeImmersiveActions(owner: immersiveActionsOwner)
        }
        let open = openImmersiveSpace
        let dismiss = dismissImmersiveSpace
        let owner = immersiveActionsOwner
        registry.installImmersiveActions(.init(
            open: { id in
                let requestID = RouterSceneLifecycleTrace.requestID()
                RouterSceneLifecycleTrace.record("actions.open.call", "request=\(String(describing: requestID)) owner=\(owner)")
                let result = await open(id: id)
                RouterSceneLifecycleTrace.record("actions.open.return", "request=\(String(describing: requestID)) owner=\(owner) result=\(String(describing: result))")
                return switch result {
                case .opened: .opened
                case .userCancelled: .userCancelled
                case .error: .error
                @unknown default: .error
                }
            },
            dismiss: { await dismiss() },
            openActivation: { activation in
                RouterSceneLifecycleTrace.record("actions.bound.open.call", "request=\(activation.requestID) owner=\(owner)")
                let result = await open(id: activation.sceneID, value: activation)
                RouterSceneLifecycleTrace.record("actions.bound.open.return", "request=\(activation.requestID) result=\(String(describing: result))")
                return switch result {
                case .opened: .opened
                case .userCancelled: .userCancelled
                case .error: .error
                @unknown default: .error
                }
            }
        ), owner: immersiveActionsOwner)
        registeredRestorationRegistry = registry
#endif
    }

    private func reconcile(
        with state: RouterState<R>,
        windowLifetimes: [UUID: UUID],
        immersiveSpaceLifetime: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async {
        RouterSceneLifecycleTrace.record("driver.reconcile", "revision=\(reconciliationID.revision) current=\(isCurrent(reconciliationID)) previousLifetime=\(String(describing: previousImmersiveSpaceLifetime)) nextLifetime=\(String(describing: immersiveSpaceLifetime)) previousStore=\(String(describing: previousStoreIdentity)) store=\(ObjectIdentifier(store))")
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

        if store.pendingImmersiveDismissal != nil || !sameNativeIdentity(
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

private extension RouterSceneDriver {
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
        guard isCurrent(reconciliationID) else { return false }
        if adoptImmersiveSpace(current, lifetime: currentLifetime) { return true }
        guard await dismissPreviousImmersiveSpace(
            previous, desired: current, expected: reconciliationID
        ) else { return false }
        guard let current else { return true }
        return await openNativeImmersiveSpace(
            current, lifetime: currentLifetime, expected: reconciliationID
        )
#else
        guard isCurrent(reconciliationID) else { return false }
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

#if os(visionOS)
    private func adoptImmersiveSpace(_ current: RouterImmersiveSpace<R>?, lifetime: UUID?) -> Bool {
        guard let current, store.hasAdoptedImmersiveAppearance(id: current.id, lifetime: lifetime) else { return false }
        if let pending = store.pendingImmersiveDismissal { store.finishAttributedImmersiveDismissal(pending.id) }
        previousImmersiveSpace = current
        previousImmersiveSpaceLifetime = lifetime
        onEvent(.openedImmersiveSpace(current))
        return true
    }

    private func dismissPreviousImmersiveSpace(
        _ previous: RouterImmersiveSpace<R>?, desired current: RouterImmersiveSpace<R>?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async -> Bool {
        if let pending = store.pendingImmersiveDismissal {
            await dismissImmersiveSpace()
            store.finishAttributedImmersiveDismissal(pending.id)
            previousImmersiveSpace = nil
            previousImmersiveSpaceLifetime = nil
            onEvent(.dismissedImmersiveSpace(pending.scene))
            guard isCurrent(reconciliationID) else { return false }
        }
        if let previous, previousImmersiveSpace != nil {
            if current == nil && store.hasClaimedImmersiveRecovery {
                previousImmersiveSpace = nil
                return true
            }
            RouterSceneLifecycleTrace.record("driver.dismiss.call", "revision=\(store.revision)")
            await dismissImmersiveSpace()
            RouterSceneLifecycleTrace.record("driver.dismiss.return", "revision=\(store.revision)")
            previousImmersiveSpace = nil
            onEvent(.dismissedImmersiveSpace(previous))
            guard isCurrent(reconciliationID) else { return false }
        }
        return true
    }

    private func openNativeImmersiveSpace(
        _ current: RouterImmersiveSpace<R>, lifetime currentLifetime: UUID?,
        expected reconciliationID: RouterSceneReconciliationID
    ) async -> Bool {
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
        let requestID = RouterSceneLifecycleTrace.requestID()
        RouterSceneLifecycleTrace.record("driver.open.call", "request=\(String(describing: requestID)) lifetime=\(String(describing: currentLifetime)) revision=\(store.revision)")
        guard let result = await performImmersiveSpaceOpen(id: scene.id, lifetime: currentLifetime) else { return false }
        RouterSceneLifecycleTrace.record("driver.open.return", "request=\(String(describing: requestID)) result=\(String(describing: result)) lifetime=\(String(describing: currentLifetime)) revision=\(store.revision)")
        guard isCurrent(reconciliationID) else {
            if result == .opened {
                await dismissImmersiveSpace()
            }
            return false
        }
        if result == .opened || store.hasAdoptedImmersiveAppearance(id: scene.id, lifetime: currentLifetime) {
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
    }

    private func performImmersiveSpaceOpen(id: String, lifetime: UUID?) async -> OpenImmersiveSpaceAction.Result? {
        let activation = if store.sceneRestorationRegistry.hasAttributedImmersiveSpace(id: id), let lifetime {
            store.beginAttributedImmersiveOpen(id: id, lifecycleToken: lifetime, owner: immersiveActionsOwner)
        } else { Optional<RouterImmersiveActivation>.none }
        if let activation {
            let result = await openImmersiveSpace(id: id, value: activation)
            let mappedResult: RouterImmersiveSpaceOpenResult = switch result {
                case .opened: .opened
                case .userCancelled: .userCancelled
                case .error: .error
                @unknown default: .error
            }
            guard store.returnedAttributedImmersiveOpen(mappedResult, activation: activation) else {
                if result == .opened { await dismissImmersiveSpace() }
                return nil
            }
            return result
        }
        if store.sceneRestorationRegistry.hasAttributedImmersiveSpace(id: id) { return .error }
        return await openImmersiveSpace(id: id)
    }
#endif
}
