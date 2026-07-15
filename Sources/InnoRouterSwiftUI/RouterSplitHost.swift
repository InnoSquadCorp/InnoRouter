import SwiftUI

import InnoRouterCore

#if !os(watchOS)
/// Environment-backed split rendering surface shared by the macro-first host
/// and focused integration tests.
///
/// The detail stack and modal presentation both render the inner stores, but
/// every published handler remains an adapter to the owning `FlowStore`.
/// Descendants therefore cannot push past a modal tail through
/// ``EnvironmentRouter`` or its explicit intent escape hatches.
struct RouterSplitFlowSurface<R: Route, Sidebar: View, Destination: View, Root: View>: View {
    @Bindable private var store: FlowStore<R>
    private let sidebar: () -> Sidebar
    private let destination: (R) -> Destination
    private let root: () -> Root

    init(
        store: FlowStore<R>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder destination: @escaping (R) -> Destination,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.store = store
        self.sidebar = sidebar
        self.destination = destination
        self.root = root
    }

    var body: some View {
        let flowStore = store
        let navigationDispatcher = flowStore.navigationIntentDispatcher
        let modalDispatcher = flowStore.modalIntentDispatcher
        let flowDispatcher = flowStore.intentDispatcher

        ModalPresentationSurface(store: flowStore.modalStore, destination: destination) {
            NavigationSplitView {
                sidebar()
            } detail: {
                NavigationStackSurface(
                    store: flowStore.navigationStore,
                    destination: destination,
                    root: root
                )
            }
        }
        .routerAuthority(
            for: R.self,
            navigation: navigationDispatcher,
            modal: modalDispatcher,
            flow: flowDispatcher
        )
    }
}

/// A macro-first split-view router that owns one local ``FlowStore``.
///
/// `RouterSplitHost` is the split-layout counterpart to ``RouterHost``. The
/// application supplies sidebar and root content, while the host owns the
/// detail navigation stack and modal presentation authority. SwiftUI retains
/// its native column visibility and compact-adaptation behavior. Descendants
/// use ``EnvironmentRouter`` for both kinds of transition. A `DeepLinkRoute`
/// automatically pushes its resolved incoming URLs into the detail stack;
/// multi-window scene selection remains a Scene-level policy.
///
/// ```swift
/// RouterSplitHost(AppRoute.self) {
///     SidebarView()
/// } root: {
///     ContentUnavailableView("Select an item", systemImage: "sidebar.left")
/// }
/// ```
///
/// Use ``NavigationSplitHost`` instead when an application boundary must own
/// and observe a stack-only `NavigationStore` directly.
@MainActor
public struct RouterSplitHost<R: DestinationRoute, Sidebar: View, Root: View>: View {
    @State private var store: FlowStore<R>
    private let sidebar: () -> Sidebar
    private let root: () -> Root

    /// Creates a locally owned split router for `routeType`.
    ///
    /// `initial` and `configuration` are captured when SwiftUI creates this
    /// host's state for the first time. Later input changes do not replace the
    /// existing store.
    public init(
        _ routeType: R.Type,
        initial: [RouteStep<R>] = [],
        configuration: FlowStoreConfiguration<R> = .init(),
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder root: @escaping () -> Root
    ) {
        _ = routeType
        self._store = State(
            initialValue: FlowStore(
                initial: initial,
                configuration: configuration.withMacroFirstDiagnostics(
                    hostName: "RouterSplitHost"
                )
            )
        )
        self.sidebar = sidebar
        self.root = root
    }

    public var body: some View {
        let flowStore = store
        RouterSplitFlowSurface(
            store: flowStore,
            sidebar: sidebar,
            destination: R.destination(for:),
            root: root
        )
        .handleRouterDeepLinks(for: R.self) { route in
            flowStore.send(.push(route))
        }
    }
}
#else
/// Split navigation is unavailable on watchOS because SwiftUI does not expose
/// `NavigationSplitView` there. Use ``RouterHost`` for a stack-plus-modal
/// authority on watchOS.
@available(
    watchOS,
    unavailable,
    message: "RouterSplitHost requires NavigationSplitView; use RouterHost on watchOS."
)
@MainActor
public struct RouterSplitHost<R: DestinationRoute, Sidebar: View, Root: View>: View {
    public init(
        _ routeType: R.Type,
        initial: [RouteStep<R>] = [],
        configuration: FlowStoreConfiguration<R> = .init(),
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder root: @escaping () -> Root
    ) {
        _ = routeType
        _ = initial
        _ = configuration
        _ = sidebar
        _ = root
    }

    public var body: some View {
        EmptyView()
    }
}
#endif
