import SwiftUI

import InnoRouterCore

/// A navigation host that owns a local ``NavigationStore`` for a
/// ``DestinationRoute``.
///
/// Use `RouterHost` for a self-contained stack that does not need external
/// access to its store. When restoration, deep-link reconciliation, or
/// middleware mutation requires an external authority, create the store at the
/// application boundary and use ``NavigationHost`` instead.
@MainActor
public struct RouterHost<R: DestinationRoute, Root: View>: View {
    @State private var store: NavigationStore<R>
    private let root: () -> Root

    /// Creates a locally owned router for `routeType`.
    ///
    /// `initial` and `configuration` are captured when SwiftUI creates this
    /// host's state for the first time. Later input changes do not replace the
    /// existing store.
    public init(
        _ routeType: R.Type,
        initial: RouteStack<R> = .init(),
        configuration: NavigationStoreConfiguration<R> = .init(),
        @ViewBuilder root: @escaping () -> Root
    ) {
        _ = routeType
        self._store = State(
            initialValue: NavigationStore(
                initial: initial,
                configuration: configuration
            )
        )
        self.root = root
    }

    public var body: some View {
        NavigationHost(store: store, root: root)
    }
}
