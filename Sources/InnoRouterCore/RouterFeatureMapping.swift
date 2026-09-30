// MARK: - RouterFeatureMapping.swift
// InnoRouterCore - typed feature-route projection
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// A structural failure while projecting one feature route through its parent.
public enum RouterFeatureProjectionError: Error, Hashable, Sendable {
    /// A value inside the feature-owned subtree does not belong to the feature.
    case routeMismatch(namespace: String)
    /// Scene creation and dismissal remain owned by the application router.
    case globalActionNotAllowed(namespace: String, action: String)
    /// A complete feature plan attempted to carry application scene state.
    case globalStateNotAllowed(namespace: String)
    /// A projected or replacement feature tree is structurally invalid.
    case invalidFeatureState(namespace: String)
}

/// Payload-free metadata for one macro-declared feature composition point.
public struct RouterFeatureCatalogEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: RouterScopeID
    public let namespace: String
    public let childRouteTypeName: String

    public init(id: RouterScopeID, namespace: String, childRouteTypeName: String) {
        self.id = id
        self.namespace = namespace
        self.childRouteTypeName = childRouteTypeName
    }
}

/// A macro-generated, bidirectional connection between an application route
/// and one independently declared feature route.
///
/// `@FeatureRoute` produces these values under the parent router's generated
/// `Feature` namespace. A mapping contains no store and owns no mutable state.
public struct RouterFeatureMapping<Parent: Route, Child: Route>: Sendable {
    /// Stable identity for this feature instance in the application router.
    public let id: RouterScopeID
    /// Stable diagnostic namespace exported by the parent composition point.
    public let namespace: String
    /// The typed enum-case connection generated at the composition root.
    public let route: CasePath<Parent, Child>

    public init(
        id: RouterScopeID,
        namespace: String,
        route: CasePath<Parent, Child>
    ) {
        self.id = id
        self.namespace = namespace
        self.route = route
    }

    /// Embeds one feature-local action into the parent route vocabulary.
    ///
    /// Whole-state plans are merged by the authority layer because they must
    /// preserve sibling application state. Scene actions are intentionally
    /// rejected: only the application composition root owns scene lifetime.
    public func embed(_ action: RouterAction<Child>) throws -> RouterAction<Parent> {
        if let embedded = embedRouteBearingAction(action) { return embedded }
        if let embedded = embedRouteIndependentAction(action) { return embedded }
        switch action {
        case .scoped(let scope, let child):
            return .scoped(scope, try embed(child))
        case .apply, .windowScoped, .immersiveSpaceScoped, .openWindow,
             .dismissWindow, .enterImmersiveSpace, .dismissImmersiveSpace:
            throw globalActionError(globalActionName(action))
        default:
            throw globalActionError("unsupported")
        }
    }

    /// Projects a complete feature-owned node from the parent route type.
    /// Every route must belong to this feature; mixed subtrees fail instead of
    /// silently dropping application routes.
    public func project(_ node: RouterNode<Parent>) throws -> RouterNode<Child> {
        switch node {
        case .stack(let stack):
            let path = try stack.path.map(extract)
            let presentation = try stack.presentation.map(project)
            return .stack(path: path, presentation: presentation)
        case .container(let container):
            let branches = try container.branches.map { branch in
                RouterBranch<Child>(id: branch.id, node: try project(branch.node))
            }
            return .container(
                try RouterContainerState(
                    style: container.style,
                    selection: container.selection,
                    branches: branches,
                    badges: container.badges,
                    split: container.split
                )
            )
        }
    }

    /// Embeds a feature-owned node without changing its container identities.
    public func embed(_ node: RouterNode<Child>) throws -> RouterNode<Parent> {
        switch node {
        case .stack(let stack):
            return .stack(
                path: stack.path.map(route.embed),
                presentation: stack.presentation.map(embed)
            )
        case .container(let container):
            let branches = try container.branches.map { branch in
                RouterBranch<Parent>(id: branch.id, node: try embed(branch.node))
            }
            return .container(
                try RouterContainerState(
                    style: container.style,
                    selection: container.selection,
                    branches: branches,
                    badges: container.badges,
                    split: container.split
                )
            )
        }
    }

    /// Projects a feature-local state. Application scenes are not represented
    /// because their lifetime belongs to the parent router.
    public func projectState(from node: RouterNode<Parent>) throws -> RouterState<Child> {
        try RouterState(root: project(node))
    }

    /// Embeds the root of a feature-local plan for merging into a parent state.
    public func embedPlanRoot(_ plan: RouterPlan<Child>) throws -> RouterNode<Parent> {
        guard plan.state.windows.isEmpty, plan.state.immersiveSpace == nil else {
            throw RouterFeatureProjectionError.globalStateNotAllowed(namespace: namespace)
        }
        return try embed(plan.state.root)
    }

    private func extract(_ value: Parent) throws -> Child {
        guard let child = route.extract(value) else {
            throw RouterFeatureProjectionError.routeMismatch(namespace: namespace)
        }
        return child
    }

    private func embed(_ presentation: RouterPresentation<Child>) -> RouterPresentation<Parent> {
        RouterPresentation(
            id: presentation.id,
            route: route.embed(presentation.route),
            style: presentation.style,
            options: presentation.options
        )
    }

    private func project(_ presentation: RouterPresentation<Parent>) throws -> RouterPresentation<Child> {
        RouterPresentation(
            id: presentation.id,
            route: try extract(presentation.route),
            style: presentation.style,
            options: presentation.options
        )
    }

    private func globalActionError(_ action: String) -> RouterFeatureProjectionError {
        .globalActionNotAllowed(namespace: namespace, action: action)
    }

    private func embedRouteBearingAction(
        _ action: RouterAction<Child>
    ) -> RouterAction<Parent>? {
        switch action {
        case .push(let value): .push(route.embed(value))
        case .pushIfNeeded(let value): .pushIfNeeded(route.embed(value))
        case .backOrPush(let value): .backOrPush(route.embed(value))
        case .replaceTop(let value): .replaceTop(route.embed(value))
        case .pushMany(let values): .pushMany(values.map(route.embed))
        case .popTo(let value): .popTo(route.embed(value))
        case .replaceStack(let values): .replaceStack(values.map(route.embed))
        case .present(let presentation): .present(embed(presentation))
        default: nil
        }
    }

    private func embedRouteIndependentAction(
        _ action: RouterAction<Child>
    ) -> RouterAction<Parent>? {
        switch action {
        case .pop(let count): .pop(count: count)
        case .popToRoot: .popToRoot
        case .dismissPresentation: .dismissPresentation
        case .setPresentationDetent(let detent): .setPresentationDetent(detent)
        case .select(let scope): .select(scope)
        case .setBadge(let count, let scope): .setBadge(count, for: scope)
        case .clearAllBadges: .clearAllBadges
        case .setSplitVisibility(let visibility): .setSplitVisibility(visibility)
        case .setPreferredCompactColumn(let column): .setPreferredCompactColumn(column)
        default: nil
        }
    }

    private func globalActionName(_ action: RouterAction<Child>) -> String {
        switch action {
        case .apply: "apply"
        case .windowScoped: "windowScoped"
        case .immersiveSpaceScoped: "immersiveSpaceScoped"
        case .openWindow: "openWindow"
        case .dismissWindow: "dismissWindow"
        case .enterImmersiveSpace: "enterImmersiveSpace"
        case .dismissImmersiveSpace: "dismissImmersiveSpace"
        default: "unknown"
        }
    }
}
