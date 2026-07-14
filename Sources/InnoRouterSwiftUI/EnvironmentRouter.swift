import SwiftUI

import InnoRouterCore

/// Type-safe navigation actions exposed by ``EnvironmentRouter``.
///
/// Use the named methods for common transitions. Send a
/// ``NavigationIntent`` directly when an advanced transition has no
/// convenience method:
///
/// ```swift
/// router.go(.detail(id: "42"))
/// router.back()
/// router.send(.replaceStack([.home, .settings]))
/// ```
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

    /// Pushes one route.
    @MainActor
    public func go(_ route: R) {
        dispatch(.go(route))
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
}

/// Reads navigation actions for a route type from the nearest InnoRouter host.
///
/// A missing or mismatched host is handled by the same
/// ``EnvironmentMissingPolicy`` used by ``EnvironmentNavigationIntent``.
/// The default `.crash` policy makes incorrect host wiring fail immediately;
/// previews and host-less snapshots can opt into `.logAndDegrade`.
///
/// ```swift
/// struct HomeView: View {
///     @EnvironmentRouter(AppRoute.self) private var router
///
///     var body: some View {
///         Button("Open detail") {
///             router.go(.detail(id: "42"))
///         }
///     }
/// }
/// ```
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
