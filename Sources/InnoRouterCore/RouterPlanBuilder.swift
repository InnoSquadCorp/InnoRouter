// MARK: - RouterPlanBuilder.swift
// InnoRouterCore - atomic whole-router plan construction
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// One declarative mutation used while constructing an atomic ``RouterPlan``.
public enum RouterPlanStep<R: Route>: Hashable, Sendable {
    /// Replaces the complete root navigation node.
    case root(RouterNode<R>)
    /// Applies one existing router action to the in-progress state.
    case action(RouterAction<R>)
    /// Replaces all regular-window destinations.
    case windows([RouterWindow<R>])
    /// Replaces or clears the one immersive-space destination.
    case immersiveSpace(RouterImmersiveSpace<R>?)

    /// Replaces a stack at `scope` using the reducer's normal invariants.
    public static func stack(
        _ path: [R],
        at scope: RouterScopePath = .root
    ) -> Self {
        .action(RouterAction.replaceStack(path).inScope(scope))
    }

    /// Selects one branch at `scope`.
    public static func select(
        _ branch: RouterScopeID,
        at scope: RouterScopePath = .root
    ) -> Self {
        .action(RouterAction.select(branch).inScope(scope))
    }

    /// Sets the exact presentation at `scope`.
    public static func presentation(
        _ presentation: RouterPresentation<R>,
        at scope: RouterScopePath = .root
    ) -> Self {
        .action(RouterAction.present(presentation).inScope(scope))
    }
}

/// Result builder for validated, exact-state router transactions.
@resultBuilder
public enum RouterPlanBuilder<R: Route> {
    public static func buildExpression(_ expression: RouterPlanStep<R>) -> [RouterPlanStep<R>] {
        [expression]
    }

    public static func buildBlock(_ components: [RouterPlanStep<R>]...) -> [RouterPlanStep<R>] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [RouterPlanStep<R>]?) -> [RouterPlanStep<R>] {
        component ?? []
    }

    public static func buildEither(first component: [RouterPlanStep<R>]) -> [RouterPlanStep<R>] {
        component
    }

    public static func buildEither(second component: [RouterPlanStep<R>]) -> [RouterPlanStep<R>] {
        component
    }

    public static func buildArray(_ components: [[RouterPlanStep<R>]]) -> [RouterPlanStep<R>] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(
        _ component: [RouterPlanStep<R>]
    ) -> [RouterPlanStep<R>] {
        component
    }
}

public extension RouterPlan {
    /// Builds one exact target from a base state and validates the final tree.
    ///
    /// Each step uses ``RouterReducer`` semantics, but no intermediate state is
    /// observable. Applying the resulting plan remains one store transition.
    init(
        from base: RouterState<R> = .rootStack,
        @RouterPlanBuilder<R> _ build: () -> [RouterPlanStep<R>]
    ) throws {
        var target = base
        for step in build() {
            switch step {
            case .root(let root):
                target.root = root
            case .action(let action):
                target = try RouterReducer.reduce(action, from: target)
            case .windows(let windows):
                target.windows = windows
            case .immersiveSpace(let immersiveSpace):
                target.immersiveSpace = immersiveSpace
            }
        }
        try target.validate()
        self.init(state: target)
    }
}
