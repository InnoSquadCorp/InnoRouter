import SwiftUI

import InnoRouterCore

/// Validated scope topology and initial native state for a two-column host.
public struct RouterTwoColumnSplitLayout: Hashable, Sendable {
    package let splitState: RouterSplitState

    public var sidebarScopeID: RouterScopeID { splitState.sidebar }
    public var detailScopeID: RouterScopeID { splitState.detail }
    public var visibility: RouterSplitVisibility { splitState.visibility }
    public var preferredCompactColumn: RouterSplitColumn {
        splitState.preferredCompactColumn
    }

    public init(
        sidebarScopeID: RouterScopeID = "sidebar",
        detailScopeID: RouterScopeID = "detail",
        visibility: RouterSplitVisibility = .automatic,
        preferredCompactColumn: RouterSplitColumn = .detail
    ) throws {
        self.splitState = try RouterSplitState(
            sidebar: sidebarScopeID,
            detail: detailScopeID,
            visibility: visibility,
            preferredCompactColumn: preferredCompactColumn
        )
    }

    public var hostShape: RouterHostShape {
        .splitTwo(
            sidebar: .init(sidebarScopeID, shape: .stack),
            detail: .init(detailScopeID, shape: .stack)
        )
    }

    public static let standard = Self(splitState: .standardTwoColumn)

    private init(splitState: RouterSplitState) {
        self.splitState = splitState
    }
}

/// Validated scope topology and initial native state for a three-column host.
public struct RouterThreeColumnSplitLayout: Hashable, Sendable {
    package let splitState: RouterSplitState

    public var sidebarScopeID: RouterScopeID { splitState.sidebar }
    public let contentScopeID: RouterScopeID
    public var detailScopeID: RouterScopeID { splitState.detail }
    public var visibility: RouterSplitVisibility { splitState.visibility }
    public var preferredCompactColumn: RouterSplitColumn {
        splitState.preferredCompactColumn
    }

    public init(
        sidebarScopeID: RouterScopeID = "sidebar",
        contentScopeID: RouterScopeID = "content",
        detailScopeID: RouterScopeID = "detail",
        visibility: RouterSplitVisibility = .automatic,
        preferredCompactColumn: RouterSplitColumn = .detail
    ) throws {
        self.splitState = try RouterSplitState(
            sidebar: sidebarScopeID,
            content: contentScopeID,
            detail: detailScopeID,
            visibility: visibility,
            preferredCompactColumn: preferredCompactColumn
        )
        self.contentScopeID = contentScopeID
    }

    public var hostShape: RouterHostShape {
        .splitThree(
            sidebar: .init(sidebarScopeID, shape: .stack),
            content: .init(contentScopeID, shape: .stack),
            detail: .init(detailScopeID, shape: .stack)
        )
    }

    public static let standard = Self(
        splitState: .standardThreeColumn,
        contentScopeID: "content"
    )

    private init(
        splitState: RouterSplitState,
        contentScopeID: RouterScopeID
    ) {
        self.splitState = splitState
        self.contentScopeID = contentScopeID
    }
}

public extension RouterTwoColumnSplitLayout {
    /// Stable meanings of opaque column roots. Change an ID when changing its
    /// meaning, then atomically replace the owning Store's complete descriptor.
    func hostRootDeclarations<R: Route>(
        for routeType: R.Type, sidebarDeclarationID: String, detailDeclarationID: String
    ) -> [RouterHostRootDeclaration<R>] {
        [
            .init(path: [sidebarScopeID], meaning: .declarationID(sidebarDeclarationID)),
            .init(path: [detailScopeID], meaning: .declarationID(detailDeclarationID)),
        ]
    }
}

public extension RouterThreeColumnSplitLayout {
    func hostRootDeclarations<R: Route>(
        for routeType: R.Type, sidebarDeclarationID: String,
        contentDeclarationID: String, detailDeclarationID: String
    ) -> [RouterHostRootDeclaration<R>] {
        [
            .init(path: [sidebarScopeID], meaning: .declarationID(sidebarDeclarationID)),
            .init(path: [contentScopeID], meaning: .declarationID(contentDeclarationID)),
            .init(path: [detailScopeID], meaning: .declarationID(detailDeclarationID)),
        ]
    }
}

#if !os(watchOS)
/// A two-column native split host with independent sidebar and detail scopes.
@MainActor
public struct RouterSplitHost<R: DestinationRoute, SidebarRoot: View, DetailRoot: View>: View {
    public static var defaultSidebarScopeID: RouterScopeID { "sidebar" }
    public static var defaultDetailScopeID: RouterScopeID { "detail" }

    @State private var ownedStore: RouterStore<R>
    private let suppliedStore: RouterStore<R>?
    private let layout: RouterTwoColumnSplitLayout
    private let linkHandling: RouterLinkHandling<R>?
    private let rootDeclarations: [RouterHostRootDeclaration<R>]
    private let presentations: RouterPresentationViewCatalog<R>
    private let sidebarRoot: () -> SidebarRoot
    private let detailRoot: () -> DetailRoot

    public init(
        _ routeType: R.Type,
        initialSidebarPath: [R] = [],
        initialPath: [R] = [],
        layout: RouterTwoColumnSplitLayout = .standard,
        sidebarDeclarationID: String,
        detailDeclarationID: String,
        configuration: RouterStoreConfiguration<R> = .init(),
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder root: @escaping () -> DetailRoot
    ) throws {
        _ = routeType
        let rootDeclarations = layout.hostRootDeclarations(for: R.self, sidebarDeclarationID: sidebarDeclarationID, detailDeclarationID: detailDeclarationID)
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = RouterHostDescriptor(root: layout.hostShape, rootDeclarations: rootDeclarations)
        }
        let splitState = layout.splitState
        let initialState = try Self.makeInitialState(
            split: splitState,
            resourceBudget: configuration.resourceBudget,
            branches: [
                RouterBranch(id: layout.sidebarScopeID, node: .stack(path: initialSidebarPath)),
                RouterBranch(id: layout.detailScopeID, node: .stack(path: initialPath)),
            ]
        )
        self.rootDeclarations = rootDeclarations
        self.presentations = presentations
        self.layout = layout
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.detailRoot = root
        self.suppliedStore = nil
        let store = try R.makeRouterStore(initialState: initialState, configuration: configuration)
        try store.validateHostRenderer(shape: layout.hostShape, at: .root, rootDeclarations: rootDeclarations)
        try presentations.validate(for: store)
        self._ownedStore = State(initialValue: store)
    }

    public init(
        store: RouterStore<R>,
        layout: RouterTwoColumnSplitLayout = .standard,
        sidebarDeclarationID: String,
        detailDeclarationID: String,
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder root: @escaping () -> DetailRoot
    ) throws(RouterHostValidationFailure) {
        let rootDeclarations = layout.hostRootDeclarations(for: R.self, sidebarDeclarationID: sidebarDeclarationID, detailDeclarationID: detailDeclarationID)
        try store.validateHostRenderer(shape: layout.hostShape, at: .root, rootDeclarations: rootDeclarations)
        try presentations.validate(for: store)
        self.rootDeclarations = rootDeclarations
        self.presentations = presentations
        self.layout = layout
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.detailRoot = root
        self.suppliedStore = store
        self._ownedStore = State(initialValue: store)
    }

    public var body: some View {
        RouterValidatedHostSurface(store: store, shape: layout.hostShape, rootDeclarations: rootDeclarations, presentations: presentations, path: .root) { rootScope in
            content(rootScope: rootScope, reconciliationRevision: rootScope.reconciliationRevision)
        }
    }

    private func content(
        rootScope: RouterScope<R>,
        reconciliationRevision _: UInt64
    ) -> some View {
        let sidebarScope = store.scope(at: rootScope.path.appending(layout.sidebarScopeID))
        let detailScope = store.scope(at: rootScope.path.appending(layout.detailScopeID))

        return NavigationSplitView(
            columnVisibility: splitVisibilityBinding(rootScope),
            preferredCompactColumn: preferredCompactColumnBinding(rootScope)
        ) {
            RouterStoreStackSurface(
                scope: sidebarScope,
                destination: R.destination(for:),
                root: sidebarRoot
            )
            .routerAuthority(sidebarScope, for: R.self)
        } detail: {
            RouterStoreStackSurface(
                scope: detailScope,
                destination: R.destination(for:),
                root: detailRoot
            )
            .routerAuthority(detailScope, for: R.self)
        }
        .routerAuthority(rootScope, for: R.self)
        .handleRouterPlans(
            for: R.self,
            scope: rootScope,
            handling: linkHandling
        ) { route, state in
            try layout.hostShape.validate(RouterStateDraft(state), at: .root, resourceBudget: store.resourceBudget)
            return try splitHostLinkPlan(route, state, resourceBudget: store.resourceBudget)
        }
    }

    private var store: RouterStore<R> { suppliedStore ?? ownedStore }

    private static func makeInitialState(
        split: RouterSplitState,
        resourceBudget: RouterResourceBudget,
        branches: [RouterBranch<R>]
    ) throws -> RouterState<R> {
        try makeSplitHostInitialState(split: split, branches: branches, resourceBudget: resourceBudget)
    }
}

/// A three-column native split host with independent sidebar, content, and
/// detail navigation histories in one canonical store.
@MainActor
public struct RouterThreeColumnSplitHost<
    R: DestinationRoute,
    SidebarRoot: View,
    ContentRoot: View,
    DetailRoot: View
>: View {
    @State private var ownedStore: RouterStore<R>
    private let suppliedStore: RouterStore<R>?
    private let layout: RouterThreeColumnSplitLayout
    private let linkHandling: RouterLinkHandling<R>?
    private let rootDeclarations: [RouterHostRootDeclaration<R>]
    private let presentations: RouterPresentationViewCatalog<R>
    private let sidebarRoot: () -> SidebarRoot
    private let contentRoot: () -> ContentRoot
    private let detailRoot: () -> DetailRoot

    public init(
        _ routeType: R.Type,
        initialSidebarPath: [R] = [],
        initialContentPath: [R] = [],
        initialDetailPath: [R] = [],
        layout: RouterThreeColumnSplitLayout = .standard,
        sidebarDeclarationID: String,
        contentDeclarationID: String,
        detailDeclarationID: String,
        configuration: RouterStoreConfiguration<R> = .init(),
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder content: @escaping () -> ContentRoot,
        @ViewBuilder detail: @escaping () -> DetailRoot
    ) throws {
        _ = routeType
        let rootDeclarations = layout.hostRootDeclarations(for: R.self, sidebarDeclarationID: sidebarDeclarationID, contentDeclarationID: contentDeclarationID, detailDeclarationID: detailDeclarationID)
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = RouterHostDescriptor(root: layout.hostShape, rootDeclarations: rootDeclarations)
        }
        let split = layout.splitState
        let initialState = try Self.makeInitialState(
            split: split,
            resourceBudget: configuration.resourceBudget,
            branches: [
                RouterBranch(id: layout.sidebarScopeID, node: .stack(path: initialSidebarPath)),
                RouterBranch(id: layout.contentScopeID, node: .stack(path: initialContentPath)),
                RouterBranch(id: layout.detailScopeID, node: .stack(path: initialDetailPath)),
            ]
        )
        self.rootDeclarations = rootDeclarations
        self.presentations = presentations
        self.layout = layout
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.contentRoot = content
        self.detailRoot = detail
        self.suppliedStore = nil
        let store = try R.makeRouterStore(initialState: initialState, configuration: configuration)
        try store.validateHostRenderer(shape: layout.hostShape, at: .root, rootDeclarations: rootDeclarations)
        try presentations.validate(for: store)
        self._ownedStore = State(initialValue: store)
    }

    public init(
        store: RouterStore<R>,
        layout: RouterThreeColumnSplitLayout = .standard,
        sidebarDeclarationID: String,
        contentDeclarationID: String,
        detailDeclarationID: String,
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder content: @escaping () -> ContentRoot,
        @ViewBuilder detail: @escaping () -> DetailRoot
    ) throws(RouterHostValidationFailure) {
        let rootDeclarations = layout.hostRootDeclarations(for: R.self, sidebarDeclarationID: sidebarDeclarationID, contentDeclarationID: contentDeclarationID, detailDeclarationID: detailDeclarationID)
        try store.validateHostRenderer(shape: layout.hostShape, at: .root, rootDeclarations: rootDeclarations)
        try presentations.validate(for: store)
        self.rootDeclarations = rootDeclarations
        self.presentations = presentations
        self.layout = layout
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.contentRoot = content
        self.detailRoot = detail
        self.suppliedStore = store
        self._ownedStore = State(initialValue: store)
    }

    public var body: some View {
        RouterValidatedHostSurface(store: store, shape: layout.hostShape, rootDeclarations: rootDeclarations, presentations: presentations, path: .root) { rootScope in
            contentView(rootScope: rootScope, reconciliationRevision: rootScope.reconciliationRevision)
        }
    }

    private func contentView(
        rootScope: RouterScope<R>,
        reconciliationRevision _: UInt64
    ) -> some View {
        let sidebarScope = store.scope(at: rootScope.path.appending(layout.sidebarScopeID))
        let contentScope = store.scope(at: rootScope.path.appending(layout.contentScopeID))
        let detailScope = store.scope(at: rootScope.path.appending(layout.detailScopeID))

        return NavigationSplitView(
            columnVisibility: splitVisibilityBinding(rootScope),
            preferredCompactColumn: preferredCompactColumnBinding(rootScope)
        ) {
            RouterStoreStackSurface(
                scope: sidebarScope,
                destination: R.destination(for:),
                root: sidebarRoot
            )
            .routerAuthority(sidebarScope, for: R.self)
        } content: {
            RouterStoreStackSurface(
                scope: contentScope,
                destination: R.destination(for:),
                root: contentRoot
            )
            .routerAuthority(contentScope, for: R.self)
        } detail: {
            RouterStoreStackSurface(
                scope: detailScope,
                destination: R.destination(for:),
                root: detailRoot
            )
            .routerAuthority(detailScope, for: R.self)
        }
        .routerAuthority(rootScope, for: R.self)
        .handleRouterPlans(
            for: R.self,
            scope: rootScope,
            handling: linkHandling
        ) { route, state in
            try layout.hostShape.validate(RouterStateDraft(state), at: .root, resourceBudget: store.resourceBudget)
            return try splitHostLinkPlan(route, state, resourceBudget: store.resourceBudget)
        }
    }

    private static func makeInitialState(
        split: RouterSplitState,
        resourceBudget: RouterResourceBudget,
        branches: [RouterBranch<R>]
    ) throws -> RouterState<R> {
        try makeSplitHostInitialState(split: split, branches: branches, resourceBudget: resourceBudget)
    }

    private var store: RouterStore<R> { suppliedStore ?? ownedStore }
}

// MARK: - Shared split-host plumbing

/// Builds the root split container both split hosts start from.
///
/// The hosts stay separate types — their bodies render different containers —
/// but this step was written twice, identical apart from the wording that
/// `hostName` now carries.
@MainActor
func makeSplitHostInitialState<R: Route>(
    split: RouterSplitState,
    branches: [RouterBranch<R>],
    resourceBudget: RouterResourceBudget = .provisional
) throws -> RouterState<R> {
    let container = try RouterContainerState<R>(
        style: .split,
        selection: split.detail,
        branches: branches,
        split: split
    )
    return try RouterStateDraft(root: .container(container)).build(resourceBudget: resourceBudget)
}

/// The root split state of `state`, or nil when its root is another shape.
func rootSplitState<R: Route>(of state: RouterState<R>) -> RouterSplitState? {
    guard case .container(let container) = state.root,
          container.style == .split else {
        return nil
    }
    return container.split
}

/// Pushes onto the declared detail role after the calling host validates its
/// frozen renderer against the exact candidate state.
func splitHostLinkPlan<R: Route>(
    _ route: R,
    _ state: RouterState<R>,
    resourceBudget: RouterResourceBudget = .provisional
) throws -> RouterPlan<R> {
    guard let split = rootSplitState(of: state) else {
        throw RouterMutationError.incompatibleNavigationTopology(.root)
    }
    let action = RouterAction<R>.push(route).inScope(split.detail)
    return RouterPlan(state: try RouterReducer.reduce(action, from: state, resourceBudget: resourceBudget))
}

@MainActor
func splitVisibilityBinding<R: Route>(
    _ rootScope: RouterScope<R>
) -> Binding<NavigationSplitViewVisibility> {
    Binding(
        get: {
            rootScope.observedSplitState?.visibility.swiftUIValue ?? .automatic
        },
        set: { visibility in
            rootScope.dispatch(
                .setSplitVisibility(.init(visibility)),
                context: .init(source: .system)
            )
        }
    )
}

@MainActor
func preferredCompactColumnBinding<R: Route>(
    _ rootScope: RouterScope<R>
) -> Binding<NavigationSplitViewColumn> {
    Binding(
        get: {
            rootScope.observedSplitState?.preferredCompactColumn.swiftUIValue ?? .detail
        },
        set: { column in
            rootScope.dispatch(
                .setPreferredCompactColumn(.init(column)),
                context: .init(source: .system)
            )
        }
    )
}

private extension RouterSplitVisibility {
    var swiftUIValue: NavigationSplitViewVisibility {
        switch self {
        case .automatic: .automatic
        case .all: .all
        case .doubleColumn: .doubleColumn
        case .detailOnly: .detailOnly
        }
    }

    init(_ value: NavigationSplitViewVisibility) {
        if value == .all {
            self = .all
        } else if value == .doubleColumn {
            self = .doubleColumn
        } else if value == .detailOnly {
            self = .detailOnly
        } else {
            self = .automatic
        }
    }
}

private extension RouterSplitColumn {
    var swiftUIValue: NavigationSplitViewColumn {
        switch self {
        case .sidebar: .sidebar
        case .content: .content
        case .detail: .detail
        }
    }

    init(_ value: NavigationSplitViewColumn) {
        if value == .sidebar {
            self = .sidebar
        } else if value == .content {
            self = .content
        } else {
            self = .detail
        }
    }
}
#else
@available(
    watchOS,
    unavailable,
    message: "RouterSplitHost requires NavigationSplitView; use RouterHost on watchOS."
)
@MainActor
public struct RouterSplitHost<R: DestinationRoute, SidebarRoot: View, DetailRoot: View>: View {
    public init(
        _ routeType: R.Type,
        initialSidebarPath: [R] = [],
        initialPath: [R] = [],
        layout: RouterTwoColumnSplitLayout = .standard,
        sidebarDeclarationID: String,
        detailDeclarationID: String,
        configuration: RouterStoreConfiguration<R> = .init(),
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder root: @escaping () -> DetailRoot
    ) {
        _ = routeType
        _ = initialSidebarPath
        _ = initialPath
        _ = layout
        _ = configuration
        _ = linkHandling
        _ = sidebar
        _ = root
    }

    public var body: some View { EmptyView() }
}
#endif
