import SwiftUI

import InnoRouterCore

/// A macro-first router host that owns the canonical ``RouterStore`` for a
/// ``DestinationRoute``.
///
/// `RouterHost` is the default self-contained surface for both push navigation
/// and modal presentation. When `R` conforms to `DeepLinkRoute`, admitted
/// incoming URLs enter the same typed action pipeline as local requests.
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
    @State private var store: RouterStore<R>
    private let root: () -> Root
    private let linkHandling: RouterLinkHandling<R>?

    /// Creates a locally owned router for `routeType`.
    ///
    /// `initialPath` and `configuration` are captured when SwiftUI creates this
    /// host's state for the first time. Later input changes do not replace the
    /// existing store.
    public init(
        _ routeType: R.Type,
        initialPath: [R] = [],
        configuration: RouterStoreConfiguration<R> = .init(),
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) {
        _ = routeType
        self._store = State(
            initialValue: R.makeRouterStore(
                initialState: .rootStack(path: initialPath),
                configuration: configuration
            )
        )
        self.root = root
        self.linkHandling = linkHandling
    }

    /// Hosts a store retained by an application boundary.
    public init(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self._store = State(initialValue: store)
        self.root = root
        self.linkHandling = linkHandling
    }

    public var body: some View {
        let scope = store.scope()
        RouterStoreStackSurface(
            scope: scope,
            destination: R.destination(for:),
            root: root
        )
            .routerAuthority(scope, for: R.self)
            .handleRouterPlans(
                for: R.self,
                scope: scope,
                handling: linkHandling
            ) { route, state in
                var target = state
                target.root = .stack(path: [route])
                try target.validate()
                return RouterPlan(state: target)
            }
    }
}
