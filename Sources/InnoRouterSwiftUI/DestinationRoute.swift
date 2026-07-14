import SwiftUI

import InnoRouterCore

/// A route that can build the SwiftUI destination for each of its cases.
///
/// `DestinationRoute` is the simple, route-owned composition boundary used by
/// ``RouterHost``. Larger applications can keep destination construction in a
/// coordinator and continue using ``NavigationHost`` directly.
public protocol DestinationRoute: Route {
    associatedtype Destination: View

    /// Builds the destination associated with `route`.
    @MainActor
    @ViewBuilder
    static func destination(for route: Self) -> Destination
}

public extension NavigationHost where R: DestinationRoute, DestinationView == R.Destination {
    /// Creates a host whose destination builder is supplied by the route type.
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
