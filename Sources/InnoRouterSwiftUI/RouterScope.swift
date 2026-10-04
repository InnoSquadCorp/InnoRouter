// MARK: - RouterScope.swift
// InnoRouterSwiftUI - read-only scoped projection of RouterStore
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
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
    public var state: RouterState<R>? { matchesCurrentLifetime ? store?.state : nil }

    var authorityRevision: UInt64 { store?.revision ?? 0 }

    var outcomeScopePath: RouterScopePath { path }

    @ObservationIgnored
    weak var store: RouterStore<R>?
    @ObservationIgnored
    private(set) var sceneLifetime: RouterSceneRequestLifetime?
    @ObservationIgnored
    private let lifetimeToken: UUID?

    init(
        path: RouterScopePath,
        node: RouterNode<R>?,
        store: RouterStore<R>,
        lifetimeToken: UUID?
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
        self.lifetimeToken = lifetimeToken
        self.sceneLifetime = store.sceneRequestLifetime(at: path)
    }

    /// Cache identity is distinct from mutation authority: a missing capture
    /// stays stable while absent, but can never acquire a later incarnation.
    func matchesCapturedLifetime(_ token: UUID?) -> Bool {
        lifetimeToken == token
    }

    var matchesCurrentLifetime: Bool {
        guard let lifetimeToken else { return false }
        return store?.scopeLifetimeToken(at: path) == lifetimeToken
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

    /// Performs an action at the owning store root while this scope is alive.
    /// Intentional replacement independent of a child lifetime must use the Store.
    public func performRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await performRoot(
            action, context: context, expectedRevision: nil, executionPrecondition: nil
        )
    }

    func performRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<R> {
        await performRoot(
            action,
            context: context,
            expectedRevision: expectedRevision,
            executionPrecondition: nil
        )
    }

    func performRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        executionPrecondition: RouterRequestPrecondition<R>?,
        authorization: RouterRequestAuthorization<R>? = nil
    ) async -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        return await store.perform(
            action,
            context: context,
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            authorization: authorization,
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition)
        )
    }

    func captureLinkAuthorizationPrecondition(
        request: RouterRequestAuthorization<R>?
    ) -> RouterRequestPrecondition<R>? {
        store?.authorizationPrecondition(request: request, existing: combinedExecutionPrecondition(nil))
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
            lifetimeMutation: .replaceSubtree(path),
            executionPrecondition: combinedExecutionPrecondition(executionPrecondition),
            executionPreparation: preparation,
            deferredResumePreparation: { state, _ in preparation(state) }
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

    @discardableResult
    func dispatchRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) -> Task<RouterOutcome<R>, Never> {
        Task { @MainActor [self] in
            return await performRoot(
                action,
                context: context,
                expectedRevision: nil,
                executionPrecondition: executionPrecondition
            )
        }
    }

    func refresh(
        from state: RouterState<R>,
        reconcileSystemBinding: Bool = false
    ) {
        // A scope acquired synchronously during commit can capture its new
        // runtime incarnation before the native scene lifetime is installed.
        // Complete that capture only while it still owns the current runtime;
        // missing and expired scopes must retain their original semantics.
        if matchesCurrentLifetime,
           let currentSceneLifetime = store?.sceneRequestLifetime(at: path),
           sceneLifetime != currentSceneLifetime {
            sceneLifetime = currentSceneLifetime
        }
        let refreshedNode = matchesCurrentLifetime ? state.node(at: path) : nil
        let projection = Self.projection(from: refreshedNode)
        let sceneRootRoute = matchesCurrentLifetime ? state.sceneRootRoute(at: path) : nil
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
        let windows = matchesCurrentLifetime ? state.windows : []
        let immersiveSpace = matchesCurrentLifetime ? state.immersiveSpace : nil
        if observedWindows != windows { observedWindows = windows }
        if observedImmersiveSpace != immersiveSpace {
            observedImmersiveSpace = immersiveSpace
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

    func presentationLifetimePrecondition(id: UUID) -> RouterRequestPrecondition<R> {
        let childPath = path.appendingPresentation(id)
        let childToken = store?.scopeLifetimeToken(at: childPath)
        let identity = RouterStore<R>.presentationIdentityPrecondition(id: id, at: path)
        return { [weak store] state in
            if let rejection = identity(state) { return rejection }
            guard let childToken, store?.scopeLifetimeToken(at: childPath) == childToken else {
                return .mutation(.expiredScope(childPath))
            }
            return nil
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

    func combinedExecutionPrecondition(
        _ supplied: RouterRequestPrecondition<R>?
    ) -> RouterRequestPrecondition<R>? {
        let token = lifetimeToken
        let path = path
        return { [weak store] state in
            guard let token, store?.scopeLifetimeToken(at: path) == token else {
                return .mutation(.expiredScope(path))
            }
            return supplied?(state)
        }
    }
}

extension RouterScope: RouterAuthorityProtocol {}
