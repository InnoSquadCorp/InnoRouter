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

#if !os(watchOS)
/// A two-column native split host with independent sidebar and detail scopes.
@MainActor
public struct RouterSplitHost<R: DestinationRoute, SidebarRoot: View, DetailRoot: View>: View {
    public static var defaultSidebarScopeID: RouterScopeID { "sidebar" }
    public static var defaultDetailScopeID: RouterScopeID { "detail" }

    @State private var ownedStore: RouterStore<R>?
    private let suppliedStore: RouterStore<R>?
    private let sidebarScopeID: RouterScopeID
    private let detailScopeID: RouterScopeID
    private let linkHandling: RouterLinkHandling<R>?
    private let sidebarRoot: () -> SidebarRoot
    private let detailRoot: () -> DetailRoot

    public init(
        _ routeType: R.Type,
        initialSidebarPath: [R] = [],
        initialPath: [R] = [],
        layout: RouterTwoColumnSplitLayout = .standard,
        configuration: RouterStoreConfiguration<R> = .init(),
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder root: @escaping () -> DetailRoot
    ) {
        _ = routeType
        let splitState = layout.splitState
        let initialState = Self.makeInitialState(
            split: splitState,
            branches: [
                RouterBranch(id: layout.sidebarScopeID, node: .stack(path: initialSidebarPath)),
                RouterBranch(id: layout.detailScopeID, node: .stack(path: initialPath)),
            ]
        )
        self.sidebarScopeID = layout.sidebarScopeID
        self.detailScopeID = layout.detailScopeID
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.detailRoot = root
        self.suppliedStore = nil
        self._ownedStore = State(
            initialValue: R.makeRouterStore(
                initialState: initialState,
                configuration: configuration
            )
        )
    }

    public init(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder root: @escaping () -> DetailRoot
    ) {
        let split = Self.requireSplitState(in: store)
        precondition(split.content == nil, "RouterSplitHost requires a two-column split state")
        self.sidebarScopeID = split.sidebar
        self.detailScopeID = split.detail
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.detailRoot = root
        self.suppliedStore = store
        self._ownedStore = State(initialValue: nil)
    }

    public var body: some View {
        let rootScope = store.scope()
        content(
            rootScope: rootScope,
            reconciliationRevision: rootScope.reconciliationRevision
        )
    }

    private func content(
        rootScope: RouterScope<R>,
        reconciliationRevision _: UInt64
    ) -> some View {
        let sidebarScope = store.scope(at: [sidebarScopeID])
        let detailScope = store.scope(at: [detailScopeID])

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
            let action = RouterAction<R>.push(route).inScope(detailScopeID)
            return RouterPlan(state: try RouterReducer.reduce(action, from: state))
        }
    }

    private static func requireSplitState(in store: RouterStore<R>) -> RouterSplitState {
        guard case .container(let container) = store.state.root,
              container.style == .split,
              let split = container.split else {
            preconditionFailure("RouterSplitHost requires a root split container")
        }
        return split
    }

    private var store: RouterStore<R> {
        resolveSplitHostStore(
            supplied: suppliedStore,
            owned: ownedStore,
            hostName: "RouterSplitHost"
        )
    }

    private static func makeInitialState(
        split: RouterSplitState,
        branches: [RouterBranch<R>]
    ) -> RouterState<R> {
        makeSplitHostInitialState(split: split, branches: branches, hostName: "two-column")
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
    @State private var ownedStore: RouterStore<R>?
    private let suppliedStore: RouterStore<R>?
    private let sidebarScopeID: RouterScopeID
    private let contentScopeID: RouterScopeID
    private let detailScopeID: RouterScopeID
    private let linkHandling: RouterLinkHandling<R>?
    private let sidebarRoot: () -> SidebarRoot
    private let contentRoot: () -> ContentRoot
    private let detailRoot: () -> DetailRoot

    public init(
        _ routeType: R.Type,
        initialSidebarPath: [R] = [],
        initialContentPath: [R] = [],
        initialDetailPath: [R] = [],
        layout: RouterThreeColumnSplitLayout = .standard,
        configuration: RouterStoreConfiguration<R> = .init(),
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder content: @escaping () -> ContentRoot,
        @ViewBuilder detail: @escaping () -> DetailRoot
    ) {
        _ = routeType
        let split = layout.splitState
        let initialState = Self.makeInitialState(
            split: split,
            branches: [
                RouterBranch(id: layout.sidebarScopeID, node: .stack(path: initialSidebarPath)),
                RouterBranch(id: layout.contentScopeID, node: .stack(path: initialContentPath)),
                RouterBranch(id: layout.detailScopeID, node: .stack(path: initialDetailPath)),
            ]
        )
        self.sidebarScopeID = layout.sidebarScopeID
        self.contentScopeID = layout.contentScopeID
        self.detailScopeID = layout.detailScopeID
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.contentRoot = content
        self.detailRoot = detail
        self.suppliedStore = nil
        self._ownedStore = State(
            initialValue: R.makeRouterStore(
                initialState: initialState,
                configuration: configuration
            )
        )
    }

    public init(
        store: RouterStore<R>,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder sidebar: @escaping () -> SidebarRoot,
        @ViewBuilder content: @escaping () -> ContentRoot,
        @ViewBuilder detail: @escaping () -> DetailRoot
    ) {
        guard case .container(let container) = store.state.root,
              container.style == .split,
              let split = container.split,
              let contentScopeID = split.content else {
            preconditionFailure(
                "RouterThreeColumnSplitHost requires a root three-column split container"
            )
        }
        self.sidebarScopeID = split.sidebar
        self.contentScopeID = contentScopeID
        self.detailScopeID = split.detail
        self.linkHandling = linkHandling
        self.sidebarRoot = sidebar
        self.contentRoot = content
        self.detailRoot = detail
        self.suppliedStore = store
        self._ownedStore = State(initialValue: nil)
    }

    public var body: some View {
        let rootScope = store.scope()
        contentView(
            rootScope: rootScope,
            reconciliationRevision: rootScope.reconciliationRevision
        )
    }

    private func contentView(
        rootScope: RouterScope<R>,
        reconciliationRevision _: UInt64
    ) -> some View {
        let sidebarScope = store.scope(at: [sidebarScopeID])
        let contentScope = store.scope(at: [contentScopeID])
        let detailScope = store.scope(at: [detailScopeID])

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
            let action = RouterAction<R>.push(route).inScope(detailScopeID)
            return RouterPlan(state: try RouterReducer.reduce(action, from: state))
        }
    }

    private static func makeInitialState(
        split: RouterSplitState,
        branches: [RouterBranch<R>]
    ) -> RouterState<R> {
        makeSplitHostInitialState(split: split, branches: branches, hostName: "three-column")
    }

    private var store: RouterStore<R> {
        resolveSplitHostStore(
            supplied: suppliedStore,
            owned: ownedStore,
            hostName: "RouterThreeColumnSplitHost"
        )
    }
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
    hostName: String
) -> RouterState<R> {
    do {
        let container = try RouterContainerState<R>(
            style: .split,
            selection: split.detail,
            branches: branches,
            split: split
        )
        return try RouterState(root: .container(container))
    } catch {
        preconditionFailure("Validated \(hostName) layout produced invalid state: \(error)")
    }
}

/// Resolves whichever store a split host ended up owning. Every initializer
/// seeds exactly one, so neither being set is an internal invariant failure.
@MainActor
func resolveSplitHostStore<R: Route>(
    supplied: RouterStore<R>?,
    owned: RouterStore<R>?,
    hostName: String
) -> RouterStore<R> {
    if let supplied { return supplied }
    guard let owned else {
        preconditionFailure("\(hostName) requires either an owned or supplied store")
    }
    return owned
}

@MainActor
private func splitVisibilityBinding<R: Route>(
    _ rootScope: RouterScope<R>
) -> Binding<NavigationSplitViewVisibility> {
    Binding(
        get: {
            rootScope.observedSplitState?.visibility.swiftUIValue ?? .automatic
        },
        set: { visibility in
            rootScope.dispatchRoot(
                .setSplitVisibility(.init(visibility)),
                context: .init(source: .system)
            )
        }
    )
}

@MainActor
private func preferredCompactColumnBinding<R: Route>(
    _ rootScope: RouterScope<R>
) -> Binding<NavigationSplitViewColumn> {
    Binding(
        get: {
            rootScope.observedSplitState?.preferredCompactColumn.swiftUIValue ?? .detail
        },
        set: { column in
            rootScope.dispatchRoot(
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
        configuration: RouterStoreConfiguration<R> = .init(),
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
