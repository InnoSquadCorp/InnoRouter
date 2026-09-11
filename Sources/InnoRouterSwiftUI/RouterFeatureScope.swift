// MARK: - RouterFeatureScope.swift
// InnoRouterSwiftUI - one-store feature route composition
// Copyright © 2026 Inno Squad. All rights reserved.

import Observation
import SwiftUI

import InnoRouterCore

/// A read-only feature projection and action forwarder backed by a parent
/// router authority.
///
/// This type never owns a `RouterStore`. Every request is embedded into the
/// parent route type and therefore uses the parent's queue, policies,
/// transition identifiers, revision check, and single commit.
@MainActor
@Observable
public final class RouterFeatureScope<Parent: Route, Child: Route> {
    public let mapping: RouterFeatureMapping<Parent, Child>

    @ObservationIgnored
    let parent: any RouterAuthorityProtocol<Parent>

    /// Creates an explicit feature projection from a retained parent scope.
    public convenience init(
        parent: RouterScope<Parent>,
        mapping: RouterFeatureMapping<Parent, Child>
    ) {
        self.init(parent: parent as any RouterAuthorityProtocol<Parent>, mapping: mapping)
    }

    /// Creates a nested feature projection without introducing another store.
    public convenience init<Grandparent: Route>(
        parent: RouterFeatureScope<Grandparent, Parent>,
        mapping: RouterFeatureMapping<Parent, Child>
    ) {
        self.init(parent: parent as any RouterAuthorityProtocol<Parent>, mapping: mapping)
    }

    init(
        parent: any RouterAuthorityProtocol<Parent>,
        mapping: RouterFeatureMapping<Parent, Child>
    ) {
        self.parent = parent
        self.mapping = mapping
    }

    public var path: RouterScopePath { parent.path }

    public var node: RouterNode<Child>? {
        parent.node.flatMap { try? mapping.project($0) }
    }

    public var state: RouterState<Child>? {
        node.flatMap { try? RouterState(root: $0) }
    }

    var observedPath: [Child] {
        guard case .stack(let stack) = node else { return [] }
        return stack.path
    }

    var observedSceneRootRoute: Child? {
        parent.observedSceneRootRoute.flatMap(mapping.route.extract)
    }

    var observedPresentation: RouterPresentation<Child>? {
        guard case .stack(let stack) = node else { return nil }
        return stack.presentation
    }

    var observedSelection: RouterScopeID? {
        guard case .container(let container) = node else { return nil }
        return container.selection
    }

    var observedBadges: [RouterScopeID: Int] {
        guard case .container(let container) = node else { return [:] }
        return container.badges
    }

    var observedSplitState: RouterSplitState? {
        guard case .container(let container) = node else { return nil }
        return container.split
    }

    // A feature can navigate inside an existing scene, but application scene
    // inventory and lifetime are deliberately absent from its projection.
    var observedWindows: [RouterWindow<Child>] { [] }
    var observedImmersiveSpace: RouterImmersiveSpace<Child>? { nil }
    var reconciliationRevision: UInt64 { parent.reconciliationRevision }
    var authorityRevision: UInt64 { parent.authorityRevision }
    var outcomeScopePath: RouterScopePath { .root }

    /// Performs one feature-local action through the parent authority.
    public func perform(
        _ action: RouterAction<Child>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<Child> {
        await perform(action, context: context, expectedRevision: nil)
    }

    func perform(
        _ action: RouterAction<Child>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<Child> {
        await perform(
            action,
            context: context,
            expectedRevision: expectedRevision,
            executionPrecondition: nil
        )
    }

    func perform(
        _ action: RouterAction<Child>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterOutcome<Child> {
        guard node != nil else {
            return projectionRejection(.routeMismatch(namespace: mapping.namespace))
        }

        if case .apply(let plan) = action {
            return await apply(
                plan,
                context: context,
                expectedRevision: expectedRevision ?? authorityRevision
            )
        }

        do {
            let embedded = try mapping.embed(action)
            let path = parent.outcomeScopePath
            let mapping = self.mapping
            let parentPrecondition: RouterRequestPrecondition<Parent> = { state in
                guard let node = state.node(at: path),
                      let projected = try? mapping.projectState(from: node) else {
                    return .featureProjection(.routeMismatch(namespace: mapping.namespace))
                }
                return childPrecondition?(projected)
            }
            return map(
                await parent.performFeatureAction(
                    embedded,
                    context: context,
                    expectedRevision: expectedRevision,
                    features: [featureCatalogEntry],
                    executionPrecondition: parentPrecondition
                )
            )
        } catch let error as RouterFeatureProjectionError {
            return projectionRejection(error)
        } catch {
            return projectionRejection(.routeMismatch(namespace: mapping.namespace))
        }
    }

    func performRoot(
        _ action: RouterAction<Child>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<Child> {
        await perform(action, context: context, expectedRevision: expectedRevision)
    }

    func performFeatureAction(
        _ action: RouterAction<Child>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        features childFeatures: [RouterFeatureCatalogEntry],
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterOutcome<Child> {
        guard node != nil else {
            return projectionRejection(.routeMismatch(namespace: mapping.namespace))
        }
        do {
            let embedded = try mapping.embed(action)
            return map(
                await parent.performFeatureAction(
                    embedded,
                    context: context,
                    expectedRevision: expectedRevision,
                    features: [featureCatalogEntry] + childFeatures,
                    executionPrecondition: parentPrecondition(childPrecondition)
                )
            )
        } catch let error as RouterFeatureProjectionError {
            return projectionRejection(error)
        } catch {
            return projectionRejection(.routeMismatch(namespace: mapping.namespace))
        }
    }

    func performFeaturePlan(
        _ node: RouterNode<Child>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        features childFeatures: [RouterFeatureCatalogEntry],
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterOutcome<Child> {
        guard self.node != nil else {
            return projectionRejection(.routeMismatch(namespace: mapping.namespace))
        }
        do {
            let state = try RouterState(root: node)
            let embedded = try mapping.embedPlanRoot(RouterPlan(state: state))
            let path = parent.outcomeScopePath
            let mapping = self.mapping
            let parentPrecondition: RouterRequestPrecondition<Parent> = { state in
                guard let node = state.node(at: path),
                      let projected = try? mapping.projectState(from: node) else {
                    return .featureProjection(.routeMismatch(namespace: mapping.namespace))
                }
                return childPrecondition?(projected)
            }
            return map(
                await parent.performFeaturePlan(
                    embedded,
                    context: context,
                    expectedRevision: expectedRevision,
                    features: [featureCatalogEntry] + childFeatures,
                    executionPrecondition: parentPrecondition
                )
            )
        } catch let error as RouterFeatureProjectionError {
            return projectionRejection(error)
        } catch {
            return projectionRejection(.invalidFeatureState(namespace: mapping.namespace))
        }
    }

    public func present<Value: Sendable>(
        _ route: Child,
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
        _ route: Child,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterPresentationOutcome<Value> {
        guard node != nil else {
            return .rejected(.featureProjection(
                .routeMismatch(namespace: mapping.namespace)
            ))
        }
        let path = parent.outcomeScopePath
        let mapping = self.mapping
        let parentPrecondition: RouterRequestPrecondition<Parent> = { state in
            guard let node = state.node(at: path),
                  let projected = try? mapping.projectState(from: node) else {
                return .featureProjection(.routeMismatch(namespace: mapping.namespace))
            }
            return childPrecondition?(projected)
        }
        return await parent.presentFeature(
            mapping.route.embed(route),
            style: style,
            options: options,
            expecting: expecting,
            features: [featureCatalogEntry],
            executionPrecondition: parentPrecondition
        )
    }

    public func present<Value: Sendable>(
        _ request: RouterPresentationRequest<Child, Value>
    ) async -> RouterPresentationOutcome<Value> {
        await present(
            request.route,
            style: request.style,
            options: request.options,
            expecting: Value.self
        )
    }

    public func finishPresentation<Value: Sendable>(returning value: Value) async throws {
        try await finishPresentation(returning: value, executionPrecondition: nil)
    }

    func finishPresentation<Value: Sendable>(
        returning value: Value,
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async throws {
        guard node != nil else { throw projectionCompletionError() }
        try await parent.finishFeaturePresentation(
            returning: value,
            features: [featureCatalogEntry],
            executionPrecondition: parentPrecondition(childPrecondition)
        )
    }

    public func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<Child, Value>,
        returning value: Value
    ) async throws {
        try await finishPresentation(
            request,
            returning: value,
            executionPrecondition: nil
        )
    }

    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<Child, Value>,
        returning value: Value,
        executionPrecondition childPrecondition: RouterRequestPrecondition<Child>?
    ) async throws {
        guard node != nil else { throw projectionCompletionError() }
        let parentRequest = RouterPresentationRequest<Parent, Value>(
            route: mapping.route.embed(request.route),
            style: request.style,
            options: request.options
        )
        try await parent.finishFeaturePresentation(
            parentRequest,
            returning: value,
            features: [featureCatalogEntry],
            executionPrecondition: parentPrecondition(childPrecondition)
        )
    }

    func reject(_ reason: RouterRejectionReason) -> RouterOutcome<Child> {
        map(parent.reject(reason))
    }

    func reportPlatformAdaptation(_ adaptation: RouterPlatformAdaptation) {
        parent.reportPlatformAdaptation(adaptation)
    }

    private func apply(
        _ plan: RouterPlan<Child>,
        context: RouterTransitionContext,
        expectedRevision: UInt64
    ) async -> RouterOutcome<Child> {
        guard plan.state.windows.isEmpty, plan.state.immersiveSpace == nil else {
            return projectionRejection(.globalStateNotAllowed(namespace: mapping.namespace))
        }
        return await performFeaturePlan(
            plan.state.root,
            context: context,
            expectedRevision: expectedRevision,
            features: [],
            executionPrecondition: nil
        )
    }

    var featureCatalogEntry: RouterFeatureCatalogEntry {
        .init(
            id: mapping.id,
            namespace: mapping.namespace,
            childRouteTypeName: String(describing: Child.self)
        )
    }

    func parentPrecondition(
        _ childPrecondition: RouterRequestPrecondition<Child>?
    ) -> RouterRequestPrecondition<Parent> {
        let path = parent.outcomeScopePath
        let mapping = self.mapping
        return { state in
            guard let node = state.node(at: path),
                  let projected = try? mapping.projectState(from: node) else {
                return .featureProjection(.routeMismatch(namespace: mapping.namespace))
            }
            return childPrecondition?(projected)
        }
    }

    func projectionCompletionError() -> RouterPresentationCompletionError {
        .dismissalRejected(.featureProjection(
            .routeMismatch(namespace: mapping.namespace)
        ))
    }

    private func map(_ outcome: RouterOutcome<Parent>) -> RouterOutcome<Child> {
        switch outcome {
        case .applied(let id, let before, let after, let revision):
            guard let before = project(before), let after = project(after) else {
                return .rejected(
                    id: id,
                    state: state ?? .rootStack,
                    revision: revision,
                    reason: .featureProjection(.routeMismatch(namespace: mapping.namespace))
                )
            }
            return .applied(id: id, before: before, after: after, revision: revision)
        case .unchanged(let id, let state, let revision):
            return .unchanged(
                id: id,
                state: project(state) ?? .rootStack,
                revision: revision
            )
        case .deferred(let id, let state, let revision, let deferral):
            return .deferred(
                id: id,
                state: project(state) ?? .rootStack,
                revision: revision,
                deferral: deferral
            )
        case .rejected(let id, let state, let revision, let reason):
            return .rejected(
                id: id,
                state: project(state) ?? .rootStack,
                revision: revision,
                reason: reason
            )
        }
    }

    private func project(_ state: RouterState<Parent>) -> RouterState<Child>? {
        guard let node = state.node(at: parent.outcomeScopePath) else { return nil }
        return try? mapping.projectState(from: node)
    }

    private func projectionRejection(
        _ error: RouterFeatureProjectionError
    ) -> RouterOutcome<Child> {
        map(parent.reject(.featureProjection(error)))
    }
}

extension RouterFeatureScope: RouterAuthorityProtocol {}

/// Publishes a macro-generated feature mapping to descendants without
/// creating another navigation store or native host.
@MainActor
public struct RouterFeatureHost<Parent: Route, Child: Route, Content: View>: View {
    @Environment(\.routerEnvironment) private var routerEnvironment
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var missingPolicy

    private let mapping: RouterFeatureMapping<Parent, Child>
    private let content: () -> Content

    public init(
        _ mapping: RouterFeatureMapping<Parent, Child>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.mapping = mapping
        self.content = content
    }

    @ViewBuilder
    public var body: some View {
        if let parent = routerEnvironment?[Parent.self] {
            let feature = RouterFeatureScope(parent: parent.base, mapping: mapping)
            content()
                .transformEnvironment(\.routerEnvironment) { environment in
                    var resolved = environment ?? RouterEnvironment()
                    resolved.register(RouterAuthority(base: feature), for: Child.self)
                    environment = resolved
                }
        } else {
            missingParentContent()
        }
    }

    private func missingParentContent() -> Content {
        handleMissingEnvironment(policy: missingPolicy) {
            "Parent router authority is missing for \(String(describing: Parent.self)) while composing feature \(mapping.namespace)."
        }
        return content()
    }
}
