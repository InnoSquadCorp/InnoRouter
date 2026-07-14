import SwiftUI

import InnoRouterCore

/// Type-safe navigation actions exposed by ``EnvironmentRouter``.
public struct RouterActions<R: Route>: Sendable {
    private let dispatch: @MainActor @Sendable (NavigationIntent<R>) -> Void

    init(
        dispatch: @escaping @MainActor @Sendable (NavigationIntent<R>) -> Void
    ) {
        self.dispatch = dispatch
    }

    /// Sends a navigation intent without exposing the underlying store.
    @MainActor
    public func send(_ intent: NavigationIntent<R>) {
        dispatch(intent)
    }

    /// Pushes `route`. This enables the shorthand `router(.detail)`.
    @MainActor
    public func callAsFunction(_ route: R) {
        go(route)
    }

    /// Pushes one route.
    @MainActor
    public func go(_ route: R) {
        dispatch(.go(route))
    }

    /// Pushes routes in order.
    @MainActor
    public func goMany(_ routes: [R]) {
        dispatch(.goMany(routes))
    }

    /// Pops one route.
    @MainActor
    public func back() {
        dispatch(.back)
    }

    /// Pops `count` routes.
    @MainActor
    public func back(by count: Int) {
        dispatch(.backBy(count))
    }

    /// Pops back to `route` when it exists in the stack.
    @MainActor
    public func back(to route: R) {
        dispatch(.backTo(route))
    }

    /// Pops every route above the root view.
    @MainActor
    public func backToRoot() {
        dispatch(.backToRoot)
    }

    /// Replaces the complete pushed-route stack.
    @MainActor
    public func replaceStack(with routes: [R]) {
        dispatch(.replaceStack(routes))
    }

    /// Pops to `route` when present, otherwise pushes it.
    @MainActor
    public func backOrGo(to route: R) {
        dispatch(.backOrPush(route))
    }

    /// Pushes `route` only when an equal route is not already present.
    @MainActor
    public func goIfNeeded(_ route: R) {
        dispatch(.pushUniqueRoot(route))
    }
}

/// Reads navigation actions for a route type from the nearest InnoRouter host.
///
/// A missing or mismatched host is handled by the same
/// ``EnvironmentMissingPolicy`` used by ``EnvironmentNavigationIntent``.
@MainActor
@propertyWrapper
public struct EnvironmentRouter<R: Route>: DynamicProperty {
    @EnvironmentNavigationIntent<R>
    private var dispatch: @MainActor @Sendable (NavigationIntent<R>) -> Void

    public init(_ routeType: R.Type) {
        self._dispatch = EnvironmentNavigationIntent(routeType)
    }

    public var wrappedValue: RouterActions<R> {
        RouterActions(dispatch: dispatch)
    }
}
