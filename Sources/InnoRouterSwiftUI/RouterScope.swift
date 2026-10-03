// MARK: - RouterScope.swift
// InnoRouterSwiftUI - read-only scoped projection of RouterStore
// Copyright © 2026 Inno Squad. All rights reserved.

import Observation

import InnoRouterCore

/// A stable, read-only projection of one subtree in a ``RouterStore``.
///
/// Scopes forward actions to their owner; they never become a second mutable
/// authority. Hosts use this projection so unrelated sibling mutations do not
/// invalidate the rendered subtree.
@MainActor
@Observable
public final class RouterScope<R: Route> {
    public let path: RouterScopePath
    public private(set) var node: RouterNode<R>?
    var observedPath: [R]
    var observedSceneRootRoute: R?
    var observedPresentation: RouterPresentation<R>?
    var observedSelection: RouterScopeID?
    var observedBadges: [RouterScopeID: Int]
    var observedSplitState: RouterSplitState?
    /// The style of this scope's container node, observed on its own so a
    /// host re-renders when its container changes shape rather than on every
    /// commit that changes the node.
    var observedContainerStyle: RouterContainerStyle?
    var observedWindows: [RouterWindow<R>]
    var observedImmersiveSpace: RouterImmersiveSpace<R>?
    /// Changes whenever SwiftUI should re-read a system navigation binding,
    /// including after a rejected or unchanged system-originated request.
    public private(set) var reconciliationRevision: UInt64 = 0

    /// The complete committed state owned by this scope's store.
    ///
    /// This is read-only and is primarily useful for deriving an atomic
    /// ``RouterPlan`` from the current tree at a host boundary.
    public var state: RouterState<R>? { store?.state }

    var authorityRevision: UInt64 { store?.revision ?? 0 }

    var outcomeScopePath: RouterScopePath { path }

    @ObservationIgnored
    private weak var store: RouterStore<R>?
    @ObservationIgnored
    private let sceneLifetime: RouterSceneRequestLifetime?

    init(
        path: RouterScopePath,
        node: RouterNode<R>?,
        store: RouterStore<R>
    ) {
        let projection = Self.projection(from: node)
        self.path = path
        self.node = node
        self.observedPath = projection.path
        self.observedSceneRootRoute = store.state.sceneRootRoute(at: path)
        self.observedPresentation = projection.presentation
        self.observedSelection = projection.selection
        self.observedBadges = projection.badges
        self.observedSplitState = projection.split
        self.observedContainerStyle = Self.containerStyle(of: node)
        self.observedWindows = store.state.windows
        self.observedImmersiveSpace = store.state.immersiveSpace
        self.store = store
        self.sceneLifetime = store.sceneRequestLifetime(at: path)
    }

    var matchesCurrentSceneLifetime: Bool {
        guard let sceneLifetime else { return path.domain == .application }
        return store?.matchesSceneRequestLifetime(sceneLifetime) == true
    }

    /// Performs an action relative to this scope.
    public func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await perform(
            action,
            context: context,
            expectedRevision: nil,
            executionPrecondition: nil
        )
    }

    func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<R> {
        guard store != nil else { return Self.missingAuthorityOutcome() }
        return await perform(
            action,
            context: context,
            expectedRevision: expectedRevision,
            executionPrecondition: nil
        )
    }

    func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        return await store.perform(
            action.inScope(path),
            context: context,
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    /// Performs an action at the owning store root.
    public func performRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        guard let store else {
            return Self.missingAuthorityOutcome()
        }
        return await store.perform(action, context: context)
    }

    func performRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        return await store.perform(
            action,
            context: context,
            expectedRevision: expectedRevision,
            bypassesPolicies: false
        )
    }

    func performFeatureAction(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        return await store.perform(
            action.inScope(path),
            context: context,
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            ),
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    func performFeaturePlan(
        _ node: RouterNode<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        let path = path
        let preparation: RouterRequestPreparationBuilder<R> = { state in
            prepareRouterFeaturePlan(node: node, at: path, in: state)
        }
        let submittedAction: RouterAction<R> = switch preparation(store.state) {
        case .action(let action): action
        case .rejected: .apply(RouterPlan(state: store.state))
        }
        return await store.perform(
            submittedAction,
            context: context,
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            requestSemantics: .featurePlan(
                scope: path,
                lifetime: sceneLifetime,
                node: node,
                features: features
            ),
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            executionPreparation: preparation,
            deferredResumePreparation: { state, _ in preparation(state) }
        )
    }

    /// Presents a route and suspends until its exact presentation returns a
    /// value, is dismissed, is cancelled, or fails policy admission.
    public func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle = .sheet,
        options: RouterPresentationOptions = .init(),
        expecting: Value.Type = Value.self
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            route,
            style: style,
            options: options,
            expecting: expecting,
            executionPrecondition: nil
        )
    }

    func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value> {
        guard let store else { return .cancelled }
        return await store.present(
            route,
            style: style,
            options: options,
            at: path,
            expecting: expecting,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    func presentFeature<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value> {
        guard let store else { return .cancelled }
        return await store.present(
            route,
            style: style,
            options: options,
            at: path,
            expecting: expecting,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            )
        )
    }

    /// Presents a macro-generated, result-typed request.
    public func present<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            request.route,
            style: request.style,
            options: request.options,
            expecting: Value.self
        )
    }

    /// Completes the exact presentation active in this scope.
    public func finishPresentation<Value: Sendable>(
        returning value: Value
    ) async throws {
        try await finishPresentation(returning: value, executionPrecondition: nil)
    }

    func finishPresentation<Value: Sendable>(
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        try await store.finishPresentation(
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    /// Completes only when the active route matches the typed request.
    public func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value
    ) async throws {
        try await finishPresentation(
            request,
            returning: value,
            executionPrecondition: nil
        )
    }

    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        try await store.finishPresentation(
            request,
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    func finishFeaturePresentation<Value: Sendable>(
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        try await store.finishPresentation(
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            )
        )
    }

    func finishFeaturePresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        guard let store else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: path)
        }
        try await store.finishPresentation(
            request,
            at: path,
            returning: value,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            requestSemantics: .featureAction(
                scope: path,
                lifetime: sceneLifetime,
                features: features
            )
        )
    }

    /// Starts a scoped fire-and-forget request.
    @discardableResult
    public func dispatch(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) -> Task<RouterOutcome<R>, Never> {
        Task { @MainActor [self] in
            return await perform(action, context: context)
        }
    }

    @discardableResult
    func dispatch(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) -> Task<RouterOutcome<R>, Never> {
        Task { @MainActor [self] in
            return await perform(
                action,
                context: context,
                expectedRevision: nil,
                executionPrecondition: executionPrecondition
            )
        }
    }

    /// Starts an action at the owning store root.
    @discardableResult
    public func dispatchRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) -> Task<RouterOutcome<R>, Never> {
        Task { @MainActor [self] in
            return await performRoot(action, context: context)
        }
    }

    func refresh(
        from state: RouterState<R>,
        reconcileSystemBinding: Bool = false
    ) {
        let refreshedNode = state.node(at: path)
        let projection = Self.projection(from: refreshedNode)
        let sceneRootRoute = state.sceneRootRoute(at: path)
        if node != refreshedNode { node = refreshedNode }
        if observedPath != projection.path { observedPath = projection.path }
        if observedSceneRootRoute != sceneRootRoute {
            observedSceneRootRoute = sceneRootRoute
        }
        if observedPresentation != projection.presentation {
            observedPresentation = projection.presentation
        }
        if observedSelection != projection.selection {
            observedSelection = projection.selection
        }
        if observedBadges != projection.badges { observedBadges = projection.badges }
        if observedSplitState != projection.split { observedSplitState = projection.split }
        let containerStyle = Self.containerStyle(of: refreshedNode)
        if observedContainerStyle != containerStyle { observedContainerStyle = containerStyle }
        if observedWindows != state.windows { observedWindows = state.windows }
        if observedImmersiveSpace != state.immersiveSpace {
            observedImmersiveSpace = state.immersiveSpace
        }
        if reconcileSystemBinding {
            reconciliationRevision &+= 1
        }
    }

    func reject(_ reason: RouterRejectionReason) -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        return store.rejectRequest(reason: reason)
    }

    func reportPlatformAdaptation(_ adaptation: RouterPlatformAdaptation) {
        store?.reportPlatformAdaptation(adaptation)
    }

    private static func containerStyle(of node: RouterNode<R>?) -> RouterContainerStyle? {
        guard case .container(let container) = node else { return nil }
        return container.style
    }

    private static func projection(
        from node: RouterNode<R>?
    ) -> (
        path: [R],
        presentation: RouterPresentation<R>?,
        selection: RouterScopeID?,
        badges: [RouterScopeID: Int],
        split: RouterSplitState?
    ) {
        switch node {
        case .some(.stack(let stack)):
            return (stack.path, stack.presentation, nil, [:], nil)
        case .some(.container(let container)):
            return ([], nil, container.selection, container.badges, container.split)
        case nil:
            return ([], nil, nil, [:], nil)
        }
    }

    private static func missingAuthorityOutcome() -> RouterOutcome<R> {
        .rejected(
            id: RouterTransitionID(),
            state: .rootStack,
            revision: 0,
            reason: .missingAuthority(routeType: String(describing: R.self))
        )
    }

    private func combinedExecutionPrecondition(
        _ supplied: RouterRequestPrecondition<R>?
    ) -> RouterRequestPrecondition<R>? {
        guard sceneLifetime != nil || supplied != nil else { return nil }
        let lifetime = sceneLifetime
        return { [weak store] state in
            if let lifetime {
                guard let store, store.matchesSceneRequestLifetime(lifetime) else {
                    return RouterStore<R>.expiredSceneLifetimeReason(lifetime)
                }
            }
            return supplied?(state)
        }
    }
}

extension RouterScope: RouterAuthorityProtocol {}
