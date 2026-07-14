import SwiftUI

import InnoRouterCore

/// A route that can build the SwiftUI destination for each of its cases.
///
/// `DestinationRoute` is the simple, route-owned composition boundary used by
/// ``RouterHost``. Larger applications can keep destination construction in a
/// coordinator and continue using ``NavigationHost`` directly.
///
/// The `@Router` macro is the default way to adopt this protocol:
///
/// ```swift
/// @Router
/// enum AppRoute {
///     case detail(id: String)
///
///     var destination: some View {
///         switch self {
///         case .detail(let id):
///             DetailView(id: id)
///         }
///     }
/// }
/// ```
///
/// Conform manually only when a route must build destinations without using
/// the macro.
public protocol DestinationRoute: Route {
    associatedtype Destination: View

    /// Builds the destination associated with `route`.
    @MainActor
    @ViewBuilder
    static func destination(for route: Self) -> Destination
}

public extension NavigationHost where R: DestinationRoute, DestinationView == R.Destination {
    /// Creates an externally owned host whose destination builder is supplied
    /// by the route type.
    ///
    /// Prefer ``RouterHost`` while the store can stay local to the view tree.
    /// Use this initializer when deep-link handling, restoration, middleware,
    /// or another application boundary needs the `NavigationStore` directly.
    init(
        store: NavigationStore<R>,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.init(
            store: store,
            destination: R.destination(for:),
            root: root
        )
    }
}
