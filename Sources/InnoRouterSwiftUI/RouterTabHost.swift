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
        // Branch drift is tolerated rather than asserted. This is a View
        // initializer, so SwiftUI re-runs it on every parent body pass, and the
        // store's branches are not always something the application chose:
        // `RouterRestorationDriver` applies a decoded snapshot through
        // `.apply`, which replaces the root wholesale, and
        // `RouterPartialRestoration` preserves branch identifiers as written.
        // A snapshot taken before a tab was renamed or removed therefore
        // reaches a host whose catalog no longer matches, and asserting there
        // aborted the process on the next render.
        //
        // Rendering is driven by the catalog, and every tab resolves through
        // `store.scope(at:)`, which yields a nil node for a branch that is not
        // present. An orphaned branch goes unused. A tab the snapshot predates
        // has no branch, and selecting it is rejected as a missing scope until
        // the store is restored with a `RouterTabRestorationTopology`. Bumping
        // `RouterSnapshotCodec.currentVersion` remains the way to reject or
        // migrate a snapshot deliberately.
        //
        // A root that is not a tabs container is tolerated for the same
        // reason. Exact restoration applies any valid decoded state, such as a
        // stack written before this router adopted tabs. Each tab still
        // resolves by ID, so it renders its catalog root over a nil node, or a
        // same-named branch of a split or custom root. The host itself never
        // writes into such a root: its default links and tab bar selection are
        // rejected, rather than trapping here.
        if !Self.hasTabsRoot(store.state) {
            RouterHostTopologyDiagnostics.reportMismatch(
                host: "RouterTabHost",
                expected: "a tabs container"
            )
        }
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

    /// Hosts application-owned state that was restored against this catalog's
    /// topology, tolerating branches the catalog no longer names.
    ///
    /// Use this with
    /// ``RouterStore/restore(from:using:tabTopology:expectedRevision:)`` and
    /// `RouterTabRestorationTopology(catalog:)` built from the same catalog.
    /// Restoration keeps a branch this catalog dropped so a later catalog can
    /// still reach it, and those orphans reach the host.
    ///
    /// Every tab in `catalog` must still have a branch: an orphan is a branch
    /// nothing renders, whereas a missing catalog branch is a tab the host
    /// cannot render. Set `allowingOrphanedBranches` to `false` for the exact
    /// set match performed by
    /// ``init(store:catalog:linkHandling:)``.
    public init(
        store: RouterStore<R>,
        catalog: RouterTabCatalog<R>,
        allowingOrphanedBranches: Bool,
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws {
        let tabScopeIDs = catalog.descriptors.map(\.tab.routerScopeID)
        guard case .container(let container) = store.state.root,
              container.style == .tabs else {
            throw RouterTabCatalogError.storeIsNotTabContainer
        }
        let present = Set(container.branches.map(\.id))
        guard let selection = container.selection, tabScopeIDs.contains(selection) else {
            throw RouterTabCatalogError.storeBranchesDoNotMatchCatalog
        }
        if allowingOrphanedBranches {
            guard present.isSuperset(of: tabScopeIDs) else {
                throw RouterTabCatalogError.storeBranchesDoNotMatchCatalog
            }
        } else {
            guard present == Set(tabScopeIDs) else {
                throw RouterTabCatalogError.storeBranchesDoNotMatchCatalog
            }
        }
        try RouterTabRestorationTopology(catalog: catalog).validateStackScopes(in: container)
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
                let selectedImage = displayedSelection(for: selectedScope(in: rootScope)) == scopeID
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
            handling: linkHandling,
            fallbackPlan: defaultLinkPlan
        )
    }

    // Shared with host integration tests so URL expectations exercise the
    // production default rather than reimplementing it in a test closure.
    func defaultLinkPlan(_ route: R, _ state: RouterState<R>) throws -> RouterPlan<R> {
        guard case .container(let container) = state.root else {
            throw RouterMutationError.expectedContainer(.root)
        }
        // A split or custom root can carry a branch named like a tab. The host
        // renders over such a root without owning its topology, so a link must
        // not select or push into that branch.
        guard container.style == .tabs else {
            throw RouterMutationError.incompatibleNavigationTopology(.root)
        }
        if let tab = tabs.first(where: { $0.root == route })?.tab {
            return RouterPlan(state: try RouterReducer.reduce(.select(tab.routerScopeID), from: state))
        }
        // Push into the tab on screen. When a restored selection names a
        // branch this catalog dropped, the host displays its first tab, and
        // pushing into the stored selection landed the route in a branch
        // nothing renders. Selecting the displayed tab in the same plan keeps
        // the state and the screen in agreement with one transition.
        let target = displayedSelection(for: container.selection)
        var prepared = state
        if container.selection != target {
            prepared = try RouterReducer.reduce(.select(target), from: prepared)
        }
        return RouterPlan(state: try RouterReducer.reduce(.scoped(target, .push(route)), from: prepared))
    }

    /// The tab the host displays for a stored `selection`.
    ///
    /// A restored selection can name a branch this catalog no longer declares,
    /// and a root of another shape may have no selection or one that is not a
    /// tab. `TabView` must stay inside the set `ForEach` renders, so the host
    /// displays its first tab instead. The selected tab image and the default
    /// link target use the same answer, so none of them disagrees with the
    /// screen.
    func displayedSelection(for selection: RouterScopeID?) -> RouterScopeID {
        guard let selection,
              tabs.contains(where: { $0.tab.routerScopeID == selection })
        else {
            return tabs[0].tab.routerScopeID
        }
        return selection
    }

    /// Dispatches a tab bar selection unless the root is another shape.
    ///
    /// Over a split or custom root the tab bar does not represent that
    /// container's selection, so a tap must not write it. The display then
    /// falls back as ``displayedSelection(for:)`` describes.
    func requestSelection(_ selection: RouterScopeID, in rootScope: RouterScope<R>) {
        guard let state = rootScope.state, Self.hasTabsRoot(state) else { return }
        rootScope.dispatchRoot(
            .select(selection),
            context: .init(source: .system)
        )
    }

    private static func hasTabsRoot(_ state: RouterState<R>) -> Bool {
        guard case .container(let container) = state.root else { return false }
        return container.style == .tabs
    }

    private func selectionBinding(_ rootScope: RouterScope<R>) -> Binding<RouterScopeID> {
        Binding(
            get: {
                displayedSelection(for: selectedScope(in: rootScope))
            },
            set: { selection in
                requestSelection(selection, in: rootScope)
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
