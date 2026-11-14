import OSLog
import SwiftUI

import InnoRouterCore

private let routerTabHostLogger = Logger(subsystem: "io.innosquad.innorouter", category: "tab-host")

/// Route types whose invalid tab declaration has already been logged. The
/// nonthrowing initializer runs on every evaluation of the parent's body.
@MainActor private var loggedInvalidTabRouteTypes: Set<ObjectIdentifier> = []

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

    /// Creates a locally owned tab router that starts on the first declared
    /// tab.
    ///
    /// This initializer does not throw, so it can be written directly in a
    /// view's `body`. A `@Router` enum's tabs are checked when it is compiled,
    /// which leaves nothing to fail here. A hand-written `routerTabs` that is
    /// not a valid catalog is reported through ``validationFailure`` and
    /// visible recovery UI, never a trap; the underlying error is logged once
    /// per route type, and a throwing initializer returns it, so hand-written
    /// conformances should use one. Use a throwing initializer also to choose
    /// the initial tab, badges, a configuration, or presentations.
    public init(_ routeType: R.Type, linkHandling: RouterLinkHandling<R>? = nil) {
        do {
            let catalog = try RouterTabCatalog(R.routerTabs)
            guard let initial = catalog.descriptors.first?.tab else { throw RouterTabCatalogError.empty }
            self = try Self(routeType, catalog: catalog, initial: initial, linkHandling: linkHandling)
        } catch {
            // No tab can be rendered. The shape below is the tabs exactly as
            // declared, so host validation names what is wrong with them where
            // it can (no tabs, a repeated scope ID); the Store behind it is an
            // empty stack and never matches. The precise cause is logged,
            // because a throwing initializer is the only way to receive it.
            if loggedInvalidTabRouteTypes.insert(ObjectIdentifier(R.self)).inserted {
                routerTabHostLogger.error(
                    "RouterTabHost could not be created from the declared tabs: \(String(describing: error), privacy: .public)"
                )
            }
            self.presentations = .stack
            self.tabs = []
            self.shape = .tabs(
                branches: R.routerTabs.map { .init($0.tab.routerScopeID, shape: .stack) },
                extras: .reject
            )
            self.rootDeclarations = []
            self.linkHandling = nil
            self.suppliedStore = nil
            self._ownedStore = State(initialValue: RouterStore<R>.makeDefaultHostedStack())
        }
    }

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
        let store = try catalog.makeHostedStore(initial: initial, badges: badges, configuration: configuration)
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

    /// A typed, payload-redacted failure for the Store's current contract,
    /// or `nil` when this host can render it. Reading this value never
    /// installs a contract or changes navigation state.
    public var validationFailure: RouterHostValidationFailure? {
        do {
            try store.validateHostRenderer(shape: shape, at: .root, rootDeclarations: rootDeclarations)
            try presentations.validate(for: store)
            return nil
        } catch {
            return error
        }
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
            fallbackPlan: defaultLinkPlanBuilder
        )
    }

    /// The plan builder handed to the link pipeline. It captures values only:
    /// a queued or deferred link request keeps it, and the Store keeps the
    /// request, so capturing this host would retain the Store.
    var defaultLinkPlanBuilder: @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R> {
        { [shape, tabs, budget = store.resourceBudget] route, state in
            try Self.defaultLinkPlan(route, state, shape: shape, tabs: tabs, resourceBudget: budget)
        }
    }

    func defaultLinkPlan(_ route: R, _ state: RouterState<R>) throws -> RouterPlan<R> {
        try defaultLinkPlanBuilder(route, state)
    }

    private static func defaultLinkPlan(
        _ route: R,
        _ state: RouterState<R>,
        shape: RouterHostShape,
        tabs: [RouterTabDescriptor<R, R.Tab>],
        resourceBudget: RouterResourceBudget
    ) throws -> RouterPlan<R> {
        try shape.validate(RouterStateDraft(state), at: .root, resourceBudget: resourceBudget)
        if let tab = tabs.first(where: { $0.root == route })?.tab {
            return RouterPlan(state: try RouterReducer.reduce(
                .select(tab.routerScopeID), from: state, resourceBudget: resourceBudget
            ))
        }
        guard case .container(let container) = state.root,
              let target = container.selection else {
            throw RouterMutationError.incompatibleNavigationTopology(.root)
        }
        return RouterPlan(state: try RouterReducer.reduce(
            .scoped(target, .push(route)), from: state, resourceBudget: resourceBudget
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
