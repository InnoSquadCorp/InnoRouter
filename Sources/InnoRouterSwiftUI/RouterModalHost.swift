import SwiftUI

import InnoRouterCore

/// A macro-first modal host that owns a local ``ModalStore`` for a
/// ``DestinationRoute``.
///
/// Use `RouterModalHost` when a feature only needs modal presentation and the
/// store does not need to escape the view tree. Use ``ModalHost`` with an
/// externally owned store for restoration, middleware management, or direct
/// observation.
@MainActor
public struct RouterModalHost<R: DestinationRoute, Content: View>: View {
    @State private var store: ModalStore<R>
    private let content: () -> Content

    /// Creates a locally owned modal router for `routeType`.
    ///
    /// `initial`, `queued`, and `configuration` are captured when SwiftUI
    /// creates this host's state for the first time. Later input changes do not
    /// replace the existing store.
    public init(
        _ routeType: R.Type,
        initial: ModalPresentation<R>? = nil,
        queued: [ModalPresentation<R>] = [],
        configuration: ModalStoreConfiguration<R> = .init(),
        @ViewBuilder content: @escaping () -> Content
    ) {
        _ = routeType
        self._store = State(
            initialValue: ModalStore(
                currentPresentation: initial,
                queuedPresentations: queued,
                configuration: configuration
            )
        )
        self.content = content
    }

    public var body: some View {
        ModalHost(
            store: store,
            destination: R.destination(for:),
            content: content
        )
    }
}
