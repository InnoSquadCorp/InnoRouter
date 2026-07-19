import SwiftUI

import InnoRouterCore

/// A macro-first modal host that owns a local ``ModalStore`` for a
/// ``DestinationRoute``.
///
/// Use `RouterModalHost` when a feature only needs modal presentation and the
/// store does not need to escape the view tree. Use ``ModalHost`` with an
/// externally owned store for restoration, middleware management, or direct
/// observation. When `R` conforms to `DeepLinkRoute`, admitted incoming URLs
/// automatically present the resolved route as a sheet by default.
@MainActor
public struct RouterModalHost<R: DestinationRoute, Content: View>: View {
    @State private var store: ModalStore<R>
    private let deepLinkStyle: ModalPresentationStyle
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
        self.init(
            routeType,
            deepLinkStyle: .sheet,
            initial: initial,
            queued: queued,
            configuration: configuration,
            content: content
        )
    }

    /// Creates a locally owned modal router with an explicit presentation
    /// style for routes resolved from incoming deep links.
    public init(
        _ routeType: R.Type,
        deepLinkStyle: ModalPresentationStyle,
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
                configuration: configuration.withMacroFirstDiagnostics(
                    hostName: "RouterModalHost"
                )
            )
        )
        self.deepLinkStyle = deepLinkStyle
        self.content = content
    }

    public var body: some View {
        let modalStore = store
        ModalHost(
            store: store,
            destination: R.destination(for:),
            content: content
        )
        .handleRouterDeepLinks(for: R.self) { route in
            modalStore.send(.present(route, style: deepLinkStyle))
        }
    }
}
