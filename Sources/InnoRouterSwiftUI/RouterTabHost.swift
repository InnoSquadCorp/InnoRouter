import SwiftUI

import InnoRouterCore

public extension RouterTabCatalog {
    /// Freezes tab root values independently of localized labels and icons.
    func hostRootDeclarations() -> [RouterHostRootDeclaration<R>] {
        descriptors.map { .init(path: [$0.tab.routerScopeID], meaning: .route($0.root)) }
    }

    /// Uses the same frozen root mapping for rendering and Store admission.
    func hostDescriptor(
        orphanPolicy: RouterHostOrphanPolicy = .reject,
        presentations: RouterHostCatalog<R> = .stack,
        windows: RouterHostCatalog<R> = .none,
        immersiveSpaces: RouterHostCatalog<R> = .none
    ) -> RouterHostDescriptor<R> {
        .init(root: hostShape(orphanPolicy: orphanPolicy), rootDeclarations: hostRootDeclarations(),
              presentations: presentations, windows: windows, immersiveSpaces: immersiveSpaces)
    }

    /// The frozen, ordered stack renderers declared by this tab catalog.
    func hostShape(orphanPolicy: RouterHostOrphanPolicy = .reject) -> RouterHostShape {
        .tabs(
            branches: descriptors.map { .init($0.tab.routerScopeID, shape: .stack) },
            extras: orphanPolicy
        )
    }
}

/// Native tabs backed by one Store and an explicit, immutable rendering catalog.
///
/// A supplied Store must already declare this host through its configuration.
/// Construction validates that declaration without changing Store state. Shape
/// changes require the owner's atomic `replaceHost` operation and a new renderer.
@MainActor
public struct RouterTabHost<R: DestinationRoute & RouterTabRoute>: View {
    @State private var ownedStore: RouterStore<R>
    private let suppliedStore: RouterStore<R>?
    private let tabs: [RouterTabDescriptor<R, R.Tab>]
    private let shape: RouterHostShape
    private let rootDeclarations: [RouterHostRootDeclaration<R>]
    private let presentations: RouterPresentationViewCatalog<R>
    private let linkHandling: RouterLinkHandling<R>?

    public init(
        _ routeType: R.Type,
        initial: R.Tab,
        badges: [R.Tab: Int] = [:],
        configuration: RouterStoreConfiguration<R> = .init(),
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws {
        try self.init(
            routeType, catalog: RouterTabCatalog(R.routerTabs), initial: initial,
            badges: badges, configuration: configuration, presentations: presentations, linkHandling: linkHandling
        )
    }

    public init(
        _ routeType: R.Type,
        catalog: RouterTabCatalog<R>,
        initial: R.Tab,
        badges: [R.Tab: Int] = [:],
        configuration: RouterStoreConfiguration<R> = .init(),
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws {
        _ = routeType
        guard catalog.descriptor(for: initial) != nil else {
            throw RouterTabCatalogError.initialTabNotInCatalog
        }
        let shape = catalog.hostShape()
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = catalog.hostDescriptor()
        }
        let container = try RouterContainerState(
            style: .tabs,
            selection: initial.routerScopeID,
            branches: catalog.descriptors.map { RouterBranch<R>(id: $0.tab.routerScopeID) },
            badges: Dictionary<RouterScopeID, Int>(uniqueKeysWithValues: badges.compactMap { tab, count in
                guard catalog.descriptor(for: tab) != nil, count > 0 else { return nil }
                return (tab.routerScopeID, count)
            })
        )
        let state = try RouterStateDraft<R>(root: .container(container))
            .build(resourceBudget: configuration.resourceBudget)
        let store = try R.makeRouterStore(initialState: state, configuration: configuration)
        try store.validateHostRenderer(shape: shape, at: .root, rootDeclarations: catalog.hostRootDeclarations())
        try presentations.validate(for: store)
        self.presentations = presentations
        self.tabs = catalog.descriptors
        self.shape = shape
        self.rootDeclarations = catalog.hostRootDeclarations()
        self.linkHandling = linkHandling
        self.suppliedStore = nil
        self._ownedStore = State(initialValue: store)
    }

    public init(
        store: RouterStore<R>,
        orphanPolicy: RouterHostOrphanPolicy = .reject,
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws {
        try self.init(
            store: store, catalog: RouterTabCatalog(R.routerTabs),
            orphanPolicy: orphanPolicy, presentations: presentations, linkHandling: linkHandling
        )
    }

    /// Orphans are rejected unless preservation is explicitly declared in both
    /// the Store contract and this renderer. Preserved branches cannot be selected.
    public init(
        store: RouterStore<R>,
        catalog: RouterTabCatalog<R>,
        orphanPolicy: RouterHostOrphanPolicy = .reject,
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil
    ) throws(RouterHostValidationFailure) {
        let shape = catalog.hostShape(orphanPolicy: orphanPolicy)
        try store.validateHostRenderer(shape: shape, at: .root, rootDeclarations: catalog.hostRootDeclarations())
        try presentations.validate(for: store)
        self.presentations = presentations
        self.tabs = catalog.descriptors
        self.shape = shape
        self.rootDeclarations = catalog.hostRootDeclarations()
        self.linkHandling = linkHandling
        self.suppliedStore = store
        self._ownedStore = State(initialValue: store)
    }

    public var body: some View {
        RouterValidatedHostSurface(store: store, shape: shape, rootDeclarations: rootDeclarations, presentations: presentations, path: .root) { rootScope in
            tabView(rootScope)
        }
    }

    private func tabView(_ rootScope: RouterScope<R>) -> some View {
        TabView(selection: selectionBinding(rootScope)) {
            ForEach(tabs) { descriptor in
                let tab = descriptor.tab
                let scopeID = tab.routerScopeID
                let scope = store.scope(at: rootScope.path.appending(scopeID))
                let image = rootScope.observedSelection == scopeID
                    ? tab.selectedSystemImage ?? tab.systemImage : tab.systemImage
                #if os(tvOS) || os(watchOS)
                routerTab(descriptor, scope: scope, image: image, rootScope: rootScope)
                #else
                routerTab(descriptor, scope: scope, image: image, rootScope: rootScope)
                    .badge(rootScope.observedBadges[scopeID] ?? 0)
                #endif
            }
        }
        .routerAuthority(rootScope, for: R.self)
        .handleRouterPlans(
            for: R.self, scope: rootScope, handling: linkHandling,
            fallbackPlan: defaultLinkPlan
        )
    }

    func defaultLinkPlan(_ route: R, _ state: RouterState<R>) throws -> RouterPlan<R> {
        try shape.validate(RouterStateDraft(state), at: .root, resourceBudget: store.resourceBudget)
        if let tab = tabs.first(where: { $0.root == route })?.tab {
            return RouterPlan(state: try RouterReducer.reduce(
                .select(tab.routerScopeID), from: state, resourceBudget: store.resourceBudget
            ))
        }
        guard case .container(let container) = state.root,
              let target = container.selection else {
            throw RouterMutationError.incompatibleNavigationTopology(.root)
        }
        return RouterPlan(state: try RouterReducer.reduce(
            .scoped(target, .push(route)), from: state, resourceBudget: store.resourceBudget
        ))
    }

    /// There is no implicit first-tab reconciliation; admission owns selection.
    func displayedSelection(for selection: RouterScopeID?) -> RouterScopeID? {
        selection
    }

    func requestSelection(_ selection: RouterScopeID, in rootScope: RouterScope<R>) {
        let shape = shape
        let budget = store.resourceBudget
        rootScope.dispatch(.select(selection), context: .init(source: .system), executionPrecondition: { state in
            do {
                try shape.validate(RouterStateDraft(state), at: .root, resourceBudget: budget)
                return nil
            } catch {
                return .mutation(.incompatibleNavigationTopology(.root))
            }
        })
    }

    private func selectionBinding(_ scope: RouterScope<R>) -> Binding<RouterScopeID?> {
        Binding(get: { scope.observedSelection }, set: { selection in
            if let selection { requestSelection(selection, in: scope) }
        })
    }

    private var store: RouterStore<R> { suppliedStore ?? ownedStore }

    private func routerTab(
        _ descriptor: RouterTabDescriptor<R, R.Tab>,
        scope: RouterScope<R>,
        image: String,
        rootScope: RouterScope<R>
    ) -> some TabContent<RouterScopeID?> {
        let tab = descriptor.tab
        return Tab(value: Optional(tab.routerScopeID), role: tab.role.swiftUITabRole) {
            RouterStoreStackSurface(
                scope: scope, destination: R.destination(for:),
                root: { R.destination(for: descriptor.root) }
            )
            .routerAuthority(scope, for: R.self)
            .routerTabBadgeDiagnostics(
                rootScope.observedBadges[tab.routerScopeID],
                scopeID: tab.routerScopeID, routerScope: rootScope
            )
        } label: {
            Label(tab.title, systemImage: image)
        }
    }
}

extension RouterTabRole {
    var swiftUITabRole: TabRole? {
        switch self {
        case .standard: nil
        case .search: .search
        }
    }
}
