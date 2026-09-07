import SwiftUI

import InnoRouterCore

/// A route that can build the SwiftUI destination for each of its cases.
///
/// `DestinationRoute` is the route-owned composition boundary used by
/// ``RouterHost``, ``RouterTabHost``, and ``RouterSplitHost``. Applications
/// that retain the authority outside a host create it with
/// ``makeRouterStore(initialState:configuration:)`` and pass it to a host.
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

public extension DestinationRoute {
    /// Creates the canonical store unlocked by `@Router`'s generated
    /// `DestinationRoute` conformance.
    @MainActor
    static func makeRouterStore(
        initialState: RouterState<Self> = .rootStack,
        configuration: RouterStoreConfiguration<Self> = .init()
    ) -> RouterStore<Self> {
        RouterStore(
            initialState: initialState,
            configuration: configuration
        )
    }
}
