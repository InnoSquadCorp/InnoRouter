import SwiftUI

import InnoRouterCore

/// A macro-first router host that owns a local ``FlowStore`` for a
/// ``DestinationRoute``.
///
/// `RouterHost` is the default self-contained surface for both push navigation
/// and modal presentation. When `R` conforms to `DeepLinkRoute`, admitted
/// incoming URLs automatically push the resolved route. Authentication,
/// pending replay, multi-step reconciliation, restoration, or middleware
/// mutation remains an application-boundary ``FlowStore`` + ``FlowHost``
/// responsibility. In multi-window apps, SwiftUI Scene-level external-event
/// policy still chooses which scene receives the URL.
///
/// ```swift
/// @Router
/// enum AppRoute {
///     case settings
///
///     var destination: some View {
///         switch self {
///         case .settings: SettingsView()
///         }
///     }
/// }
///
/// struct AppRoot: View {
///     var body: some View {
///         RouterHost(AppRoute.self) {
///             HomeView()
///         }
///     }
/// }
/// ```
@MainActor
public struct RouterHost<R: DestinationRoute, Root: View>: View {
    @State private var store: FlowStore<R>
    private let root: () -> Root

    /// Creates a locally owned router for `routeType`.
    ///
    /// `initial` and `configuration` are captured when SwiftUI creates this
    /// host's state for the first time. Later input changes do not replace the
    /// existing store.
    public init(
        _ routeType: R.Type,
        initial: [RouteStep<R>] = [],
        configuration: FlowStoreConfiguration<R> = .init(),
        @ViewBuilder root: @escaping () -> Root
    ) {
        _ = routeType
        self._store = State(
            initialValue: FlowStore(
                initial: initial,
                configuration: configuration.withMacroFirstDiagnostics()
            )
        )
        self.root = root
    }

    public var body: some View {
        let flowStore = store
        FlowHost(store: flowStore, root: root)
            .handleRouterDeepLinks(for: R.self) { route in
                flowStore.send(.push(route))
            }
    }
}
