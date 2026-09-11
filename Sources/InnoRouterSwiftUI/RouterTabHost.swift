import SwiftUI

import InnoRouterCore

/// A macro-first native tab host backed by one canonical ``RouterStore``.
///
/// Cases carrying `@TabItem` become tab roots. Unmarked cases in the same
/// `@Router` enum remain ordinary push or presentation destinations, allowing
/// one route type and one store to own the complete tab hierarchy.
@MainActor
public struct RouterTabHost<R: DestinationRoute & RouterTabRoute>: View {
    @State private var ownedStore: RouterStore<R>?
    private let suppliedStore: RouterStore<R>?
    private let tabs: [RouterTabDescriptor<R, R.Tab>]
    private let linkHandling: RouterLinkHandling<R>?

    /// Creates a tab tree with one stack scope per macro-declared tab root.
    public init(
        _ routeType: R.Type,
        initial: R.Tab,
        badges: [R.Tab: Int] = [:],
        configuration: RouterStoreConfiguration<R> = .init(),
        linkHandling: RouterLinkHandling<R>? = nil
    ) {
        _ = routeType
        let catalog: RouterTabCatalog<R>
        do {
            catalog = try RouterTabCatalog(R.routerTabs)
        } catch {
            preconditionFailure("@Router generated an invalid tab catalog: \(error)")
        }
        let tabs = catalog.descriptors
        precondition(
            catalog.descriptor(for: initial) != nil,
            "@Router initial tab must belong to its generated catalog"
        )
        let branches = tabs.map { descriptor in
            RouterBranch<R>(id: descriptor.tab.routerScopeID)
        }
        let badgePairs: [(RouterScopeID, Int)] = badges.compactMap { tab, count in
                guard R.routerTab(for: tab) != nil, count > 0 else { return nil }
                return (tab.routerScopeID, count)
            }
        let badgeState = Dictionary<RouterScopeID, Int>(
            uniqueKeysWithValues: badgePairs
        )
        let container = try! RouterContainerState(
            style: .tabs,
            selection: initial.routerScopeID,
            branches: branches,
            badges: badgeState
        )
        let initialState = try! RouterState<R>(root: .container(container))
        self.tabs = tabs
        self.linkHandling = linkHandling
        self.suppliedStore = nil
        self._ownedStore = State(
            initialValue: R.makeRouterStore(
                initialState: initialState,
                configuration: configuration
            )
        )
    }

    /// Creates a host from an explicitly validated manual tab catalog.
    public init(
        _ routeType: R.Type,
        catalog: RouterTabCatalog<R>,
        initial: R.Tab,
        badges: [R.Tab: Int] = [:],
        configuration: RouterStoreConfiguration<R> = .init(),
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws {
        _ = routeType
        guard catalog.descriptor(for: initial) != nil else {
            throw RouterTabCatalogError.initialTabNotInCatalog
        }
        let tabs = catalog.descriptors
        let branches = tabs.map { descriptor in
            RouterBranch<R>(id: descriptor.tab.routerScopeID)
        }
        let badgeState = Dictionary<RouterScopeID, Int>(
            uniqueKeysWithValues: badges.compactMap { tab, count in
                guard catalog.descriptor(for: tab) != nil, count > 0 else { return nil }
                return (tab.routerScopeID, count)
            }
        )
        let container = try RouterContainerState(
            style: .tabs,
            selection: initial.routerScopeID,
            branches: branches,
            badges: badgeState
        )
        let initialState = try RouterState<R>(root: .container(container))
        self.tabs = tabs
        self.linkHandling = linkHandling
        self.suppliedStore = nil
        self._ownedStore = State(
            initialValue: R.makeRouterStore(
                initialState: initialState,
                configuration: configuration
            )
        )
    }

    /// Hosts a tab-shaped state retained by an application boundary.
    public init(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil
    ) {
        let catalog: RouterTabCatalog<R>
        do {
            catalog = try RouterTabCatalog(R.routerTabs)
        } catch {
            preconditionFailure("@Router generated an invalid tab catalog: \(error)")
        }
        let tabScopeIDs = catalog.descriptors.map(\.tab.routerScopeID)
        guard case .container(let container) = store.state.root,
              container.style == .tabs else {
            preconditionFailure("RouterTabHost requires a root tabs container")
        }
        precondition(
            Set(container.branches.map(\.id)) == Set(tabScopeIDs),
            "RouterTabHost store branches must match RouterTabRoute.routerTabs"
        )
        self.tabs = catalog.descriptors
        self.linkHandling = linkHandling
        self.suppliedStore = store
        self._ownedStore = State(initialValue: nil)
    }

    /// Hosts application-owned state using a validated manual tab catalog.
    public init(
        store: RouterStore<R>,
        catalog: RouterTabCatalog<R>,
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws {
        let tabScopeIDs = catalog.descriptors.map(\.tab.routerScopeID)
        guard case .container(let container) = store.state.root,
              container.style == .tabs else {
            throw RouterTabCatalogError.storeIsNotTabContainer
        }
        guard Set(container.branches.map(\.id)) == Set(tabScopeIDs) else {
            throw RouterTabCatalogError.storeBranchesDoNotMatchCatalog
        }
        self.tabs = catalog.descriptors
        self.linkHandling = linkHandling
        self.suppliedStore = store
        self._ownedStore = State(initialValue: nil)
    }

    public var body: some View {
        let rootScope = store.scope()

        TabView(selection: selectionBinding(rootScope)) {
            ForEach(tabs) { descriptor in
                let tab = descriptor.tab
                let scopeID = tab.routerScopeID
                let scope = store.scope(at: RouterScopePath([scopeID]))
                let selectedImage = selectedScope(in: rootScope) == scopeID
                    ? tab.selectedSystemImage ?? tab.systemImage
                    : tab.systemImage
                #if os(tvOS) || os(watchOS)
                routerTab(
                    descriptor,
                    scope: scope,
                    scopeID: scopeID,
                    selectedImage: selectedImage,
                    rootScope: rootScope
                )
                #else
                routerTab(
                    descriptor,
                    scope: scope,
                    scopeID: scopeID,
                    selectedImage: selectedImage,
                    rootScope: rootScope
                )
                .badge(badge(for: scopeID, in: rootScope) ?? 0)
                #endif
            }
        }
        .routerAuthority(rootScope, for: R.self)
        .handleRouterPlans(
            for: R.self,
            scope: rootScope,
            handling: linkHandling
        ) { route, state in
            let action: RouterAction<R>
            if let tab = tabs.first(where: { $0.root == route })?.tab {
                action = .select(tab.routerScopeID)
            } else if case .container(let container) = state.root,
                      let selected = container.selection {
                action = .scoped(selected, .push(route))
            } else {
                throw RouterMutationError.expectedContainer(.root)
            }
            return RouterPlan(state: try RouterReducer.reduce(action, from: state))
        }
    }

    private func selectionBinding(_ rootScope: RouterScope<R>) -> Binding<RouterScopeID> {
        Binding(
            get: {
                selectedScope(in: rootScope) ?? tabs[0].tab.routerScopeID
            },
            set: { selection in
                rootScope.dispatchRoot(
                    .select(selection),
                    context: .init(source: .system)
                )
            }
        )
    }

    private var store: RouterStore<R> {
        if let suppliedStore { return suppliedStore }
        guard let ownedStore else {
            preconditionFailure("RouterTabHost requires either an owned or supplied store")
        }
        return ownedStore
    }

    private func selectedScope(in rootScope: RouterScope<R>) -> RouterScopeID? {
        rootScope.observedSelection
    }

    private func badge(
        for scope: RouterScopeID,
        in rootScope: RouterScope<R>
    ) -> Int? {
        rootScope.observedBadges[scope]
    }

    private func routerTab(
        _ descriptor: RouterTabDescriptor<R, R.Tab>,
        scope: RouterScope<R>,
        scopeID: RouterScopeID,
        selectedImage: String,
        rootScope: RouterScope<R>
    ) -> some TabContent<RouterScopeID> {
        let tab = descriptor.tab
        return Tab(value: scopeID, role: tab.role.swiftUITabRole) {
            RouterStoreStackSurface(
                scope: scope,
                destination: R.destination(for:),
                root: { R.destination(for: descriptor.root) }
            )
            .routerAuthority(scope, for: R.self)
            .routerTabBadgeDiagnostics(
                badge(for: scopeID, in: rootScope),
                scopeID: scopeID,
                routerScope: rootScope
            )
        } label: {
            Label(tab.title, systemImage: selectedImage)
        }
    }
}

private extension RouterTabRole {
    var swiftUITabRole: TabRole? {
        switch self {
        case .standard: nil
        case .search: .search
        }
    }
}
