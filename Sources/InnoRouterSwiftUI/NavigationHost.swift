import SwiftUI

import InnoRouterCore

/// Environment-free stack rendering surface shared by public hosts.
///
/// Dispatcher and router authority publication deliberately live at the
/// public host boundary. `FlowHost` can therefore reuse this surface without
/// exposing its inner `NavigationStore` as an independent mutation authority.
struct NavigationStackSurface<R: Route, DestinationView: View, Root: View>: View {
    @Bindable private var store: NavigationStore<R>
    private let destination: (R) -> DestinationView
    private let root: () -> Root

    init(
        store: NavigationStore<R>,
        @ViewBuilder destination: @escaping (R) -> DestinationView,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.store = store
        self.destination = destination
        self.root = root
    }

    var body: some View {
        NavigationStack(path: store.pathBinding) {
            root()
                .navigationDestination(for: R.self) { route in
                    destination(route)
                }
        }
    }
}

/// Hosts a stack-based navigation surface backed by a `NavigationStore`.
///
/// This is the externally owned authority tier. For a self-contained route,
/// declare it with `@Router` and use ``RouterHost`` so callers do not have to
/// create, retain, or expose the store themselves.
///
/// Ownership split:
///
/// - The `NavigationStore` is owned by the caller and outlives this host.
/// - ``NavigationStore/intentDispatcher`` is cached on the store, so the
///   host reads it instead of allocating a fresh closure per render.
/// - The route-type lookup table (``NavigationEnvironmentStorage``) is
///   `@State` because it scopes to the host's view-tree subtree, not to
///   the store's lifetime — multiple hosts can share a store while
///   maintaining distinct handler tables.
public struct NavigationHost<R: Route, DestinationView: View, Root: View>: View {
    @Bindable private var store: NavigationStore<R>
    @State private var navigationEnvironmentStorage = NavigationEnvironmentStorage()
    private let destination: (R) -> DestinationView
    private let root: () -> Root

    /// Creates a navigation host with destination and root builders.
    public init(
        store: NavigationStore<R>,
        @ViewBuilder destination: @escaping (R) -> DestinationView,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.store = store
        self.destination = destination
        self.root = root
    }

    public var body: some View {
        NavigationStackSurface(store: store, destination: destination, root: root)
            .navigationIntentDispatcher(store.intentDispatcher, owner: store)
            .environment(\.navigationEnvironmentStorage, navigationEnvironmentStorage)
            .routerAuthority(
                for: R.self,
                navigation: store.intentDispatcher
            )
    }
}

// MARK: - Platform: NavigationSplitView is unavailable on watchOS.
// `NavigationSplitHost` is therefore declared only on non-watchOS platforms.
// watchOS consumers should fall back to `NavigationHost`.
#if !os(watchOS)
/// Hosts a split-view navigation surface whose detail column is driven by a `NavigationStore`.
///
/// - Important: This host is **not available on watchOS** because SwiftUI's
///   `NavigationSplitView` is unavailable there. Use ``NavigationHost``
///   inside a `#if !os(watchOS)` fallback on watchOS targets.
public struct NavigationSplitHost<R: Route, Sidebar: View, DestinationView: View, Root: View>: View {
    @Bindable private var store: NavigationStore<R>
    @State private var navigationEnvironmentStorage = NavigationEnvironmentStorage()
    private let sidebar: () -> Sidebar
    private let destination: (R) -> DestinationView
    private let root: () -> Root

    /// Creates a split navigation host with separate sidebar, destination, and root builders.
    public init(
        store: NavigationStore<R>,
        @ViewBuilder sidebar: @escaping () -> Sidebar,
        @ViewBuilder destination: @escaping (R) -> DestinationView,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.store = store
        self.sidebar = sidebar
        self.destination = destination
        self.root = root
    }

    public var body: some View {
        NavigationSplitView {
            sidebar()
        } detail: {
            NavigationStackSurface(
                store: store,
                destination: destination,
                root: root
            )
        }
        .navigationIntentDispatcher(store.intentDispatcher, owner: store)
        .environment(\.navigationEnvironmentStorage, navigationEnvironmentStorage)
        .routerAuthority(
            for: R.self,
            navigation: store.intentDispatcher
        )
    }
}
#endif
