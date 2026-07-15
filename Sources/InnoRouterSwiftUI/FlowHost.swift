import SwiftUI

import InnoRouterCore

/// Hosts a unified flow surface combining push-based navigation and modal
/// presentation, backed by a `FlowStore`.
///
/// `FlowHost` composes environment-free navigation and modal rendering
/// surfaces around the store's inner stores. Every ``EnvironmentRouter``
/// action dispatches through `FlowStore`, preserving unified-flow invariants.
public struct FlowHost<R: Route, Destination: View, Root: View>: View {
    @Bindable private var store: FlowStore<R>
    private let destination: (R) -> Destination
    private let root: () -> Root

    /// Creates a flow host with destination and root builders.
    public init(
        store: FlowStore<R>,
        @ViewBuilder destination: @escaping (R) -> Destination,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.store = store
        self.destination = destination
        self.root = root
    }

    public var body: some View {
        let flowStore = store
        let navigationDispatcher = flowStore.navigationIntentDispatcher
        let modalDispatcher = flowStore.modalIntentDispatcher
        let flowDispatcher = flowStore.intentDispatcher

        ModalPresentationSurface(store: flowStore.modalStore, destination: destination) {
            NavigationStackSurface(
                store: flowStore.navigationStore,
                destination: destination,
                root: root
            )
        }
        .routerAuthority(
            for: R.self,
            navigation: navigationDispatcher,
            modal: modalDispatcher,
            flow: flowDispatcher
        )
    }
}

public extension FlowHost where R: DestinationRoute, Destination == R.Destination {
    /// Creates an externally owned flow host whose destination builder is
    /// supplied by the route type.
    ///
    /// Prefer ``RouterHost`` while the `FlowStore` can stay local to the view
    /// tree. Use this initializer when an application boundary must retain the
    /// store for restoration, deep links, middleware, or observation.
    init(
        store: FlowStore<R>,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.init(
            store: store,
            destination: R.destination(for:),
            root: root
        )
    }
}
