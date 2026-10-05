import SwiftUI

import InnoRouterCore

/// A frozen SwiftUI renderer paired with the exact shape it implements.
///
/// Build declarations from application code, never from the Store's current
/// state. Type erasure permits heterogeneous child roots without another Store.
/// Root and label closures receive the same read-only child scope that owns
/// their navigation. Route destinations retain `DestinationRoute` composition.
@MainActor
public struct RouterHostViewDescriptor<R: DestinationRoute> {
    public let shape: RouterHostShape
    private let renderContent: (RouterScope<R>) -> AnyView

    private init(shape: RouterHostShape, render: @escaping (RouterScope<R>) -> AnyView) {
        self.shape = shape
        self.renderContent = render
    }

    public static func stack<Root: View>(
        @ViewBuilder root: @escaping (RouterScope<R>) -> Root
    ) -> Self {
        Self(shape: .stack) { scope in
            AnyView(RouterStoreStackSurface(
                scope: scope, destination: R.destination(for:), root: { root(scope) }
            ).routerAuthority(scope, for: R.self))
        }
    }

    public static func tabs(
        _ tabs: [RouterHostTabView<R>],
        orphanPolicy: RouterHostOrphanPolicy = .reject
    ) -> Self {
        Self(shape: .tabs(
            branches: tabs.map { .init($0.id, shape: $0.content.shape) },
            extras: orphanPolicy
        )) { scope in
            AnyView(RouterDescriptorTabsSurface(scope: scope, tabs: tabs))
        }
    }

    #if !os(watchOS)
    public static func splitTwo(
        sidebar: RouterHostViewBranch<R>,
        detail: RouterHostViewBranch<R>
    ) -> Self {
        Self(shape: .splitTwo(
            sidebar: .init(sidebar.id, shape: sidebar.content.shape),
            detail: .init(detail.id, shape: detail.content.shape)
        )) { scope in
            AnyView(NavigationSplitView(
                columnVisibility: splitVisibilityBinding(scope),
                preferredCompactColumn: preferredCompactColumnBinding(scope)
            ) {
                sidebar.render(in: scope)
            } detail: {
                detail.render(in: scope)
            }.routerAuthority(scope, for: R.self))
        }
    }

    public static func splitThree(
        sidebar: RouterHostViewBranch<R>,
        content: RouterHostViewBranch<R>,
        detail: RouterHostViewBranch<R>
    ) -> Self {
        Self(shape: .splitThree(
            sidebar: .init(sidebar.id, shape: sidebar.content.shape),
            content: .init(content.id, shape: content.content.shape),
            detail: .init(detail.id, shape: detail.content.shape)
        )) { scope in
            AnyView(NavigationSplitView(
                columnVisibility: splitVisibilityBinding(scope),
                preferredCompactColumn: preferredCompactColumnBinding(scope)
            ) {
                sidebar.render(in: scope)
            } content: {
                content.render(in: scope)
            } detail: {
                detail.render(in: scope)
            }.routerAuthority(scope, for: R.self))
        }
    }
    #endif

    /// The layout receives ordered, already scoped child views. Each child can
    /// be rendered directly and forwards actions to the owning Store.
    public static func custom<Content: View>(
        declarationID: String,
        branches: [RouterHostViewBranch<R>],
        orphanPolicy: RouterHostOrphanPolicy = .reject,
        @ViewBuilder content: @escaping (RouterScope<R>, [RouterHostRenderedBranch<R>]) -> Content
    ) -> Self {
        Self(shape: .custom(
            declarationID: declarationID,
            branches: branches.map { .init($0.id, shape: $0.content.shape) },
            extras: orphanPolicy
        )) { scope in
            guard let store = scope.store, scope.matchesCurrentLifetime else {
                return AnyView(RouterHostRecoveryView(failure: .init(code: .stale, scope: scope.path)))
            }
            let rendered = branches.map { branch in
                RouterHostRenderedBranch(
                    id: branch.id, scope: store.scope(at: scope.path.appending(branch.id)),
                    content: branch.content
                )
            }
            return AnyView(content(scope, rendered).routerAuthority(scope, for: R.self))
        }
    }

    func render(_ scope: RouterScope<R>) -> AnyView {
        // Observe lifetime retirement even when an application retains one of
        // the custom layout's rendered child values outside its parent body.
        guard let store = scope.store else {
            return AnyView(RouterHostRecoveryView(failure: .init(code: .stale, scope: scope.path)))
        }
        _ = store.observesScopeLifetime(at: scope.path)
        guard scope.matchesCurrentLifetime else {
            return AnyView(RouterHostRecoveryView(failure: .init(code: .stale, scope: scope.path)))
        }
        return renderContent(scope)
    }
}

/// One explicitly named child renderer in a split or custom container.
@MainActor
public struct RouterHostViewBranch<R: DestinationRoute>: Identifiable {
    public let id: RouterScopeID
    public let content: RouterHostViewDescriptor<R>

    public init(_ id: RouterScopeID, content: RouterHostViewDescriptor<R>) {
        self.id = id
        self.content = content
    }

    @ViewBuilder
    func render(in parent: RouterScope<R>) -> some View {
        if let store = parent.store, parent.matchesCurrentLifetime {
            content.render(store.scope(at: parent.path.appending(id)))
        } else {
            RouterHostRecoveryView(failure: .init(code: .stale, scope: parent.path))
        }
    }
}

/// A tab's content and label both receive its identical child scope.
@MainActor
public struct RouterHostTabView<R: DestinationRoute>: Identifiable {
    public let id: RouterScopeID
    public let content: RouterHostViewDescriptor<R>
    public let role: RouterTabRole
    let label: (RouterScope<R>) -> AnyView

    public init<Label: View>(
        _ id: RouterScopeID,
        content: RouterHostViewDescriptor<R>,
        role: RouterTabRole = .standard,
        @ViewBuilder label: @escaping (RouterScope<R>) -> Label
    ) {
        self.id = id
        self.content = content
        self.role = role
        self.label = { AnyView(label($0)) }
    }
}

/// A child view supplied to an application's custom container layout.
@MainActor
public struct RouterHostRenderedBranch<R: DestinationRoute>: View, Identifiable {
    public let id: RouterScopeID
    public let scope: RouterScope<R>
    private let content: RouterHostViewDescriptor<R>

    init(id: RouterScopeID, scope: RouterScope<R>, content: RouterHostViewDescriptor<R>) {
        self.id = id
        self.scope = scope
        self.content = content
    }

    public var body: some View {
        content.render(scope).routerAuthority(scope, for: R.self)
    }
}

/// Renders an explicit stack/tab/split/custom declaration at an existing scope.
/// This host never owns or creates a child Store. Its captured scope expires
/// when its subtree is replaced, even if the replacement reuses persisted IDs.
@MainActor
public struct RouterScopedHost<R: DestinationRoute>: View {
    private let scope: RouterScope<R>
    private let rendering: RouterHostViewDescriptor<R>

    public init(
        scope: RouterScope<R>,
        rendering: RouterHostViewDescriptor<R>
    ) throws(RouterHostValidationFailure) {
        guard let store = scope.store, scope.matchesCurrentLifetime else {
            throw .init(code: .stale, scope: scope.path)
        }
        try store.validateHostRenderer(shape: rendering.shape, at: scope.path)
        self.scope = scope
        self.rendering = rendering
    }

    private var isCurrent: Bool {
        guard let store = scope.store else { return false }
        _ = store.observesScopeLifetime(at: scope.path)
        return scope.matchesCurrentLifetime
    }

    public var body: some View {
        if isCurrent, let store = scope.store {
            RouterValidatedHostSurface(store: store, shape: rendering.shape, path: scope.path) { _ in
                rendering.render(scope)
            }
        } else {
            RouterHostRecoveryView(failure: .init(code: .stale, scope: scope.path))
        }
    }
}

/// Explicit, payload-redacted recovery UI for a previously mounted renderer
/// whose owning Store changed shape. Constructors throw before mounting.
@MainActor
public struct RouterHostRecoveryView: View {
    public let failure: RouterHostValidationFailure

    public init(failure: RouterHostValidationFailure) {
        self.failure = failure
    }

    public var body: some View {
        VStack {
            Text("Navigation unavailable")
            Text(failure.description)
        }
        .accessibilityIdentifier(failure.code.rawValue)
    }
}

/// Rechecks live Store admission without modifying the Store from View work.
/// An owner can deliberately replace the contract while this old View remains
/// mounted. Render visible recovery, never an invented empty branch scope.
@MainActor
struct RouterValidatedHostSurface<R: Route, Content: View>: View {
    let store: RouterStore<R>
    let shape: RouterHostShape
    let path: RouterScopePath
    @ViewBuilder let content: (RouterScope<R>) -> Content

    var body: some View {
        if let failure = failure {
            RouterHostRecoveryView(failure: failure)
        } else {
            content(store.scope(at: path))
        }
    }

    private var failure: RouterHostValidationFailure? {
        do {
            try store.validateHostRenderer(shape: shape, at: path)
            return nil
        } catch {
            return error
        }
    }
}

@MainActor
private struct RouterDescriptorTabsSurface<R: DestinationRoute>: View {
    let scope: RouterScope<R>
    let tabs: [RouterHostTabView<R>]

    var body: some View {
        if let store = scope.store, scope.matchesCurrentLifetime {
            TabView(selection: selection) {
                ForEach(tabs) { tab in
                    let child = store.scope(at: scope.path.appending(tab.id))
                    #if os(tvOS) || os(watchOS)
                    tabContent(tab, scope: child)
                    #else
                    tabContent(tab, scope: child).badge(scope.observedBadges[tab.id] ?? 0)
                    #endif
                }
            }
            .routerAuthority(scope, for: R.self)
        } else {
            RouterHostRecoveryView(failure: .init(code: .stale, scope: scope.path))
        }
    }

    private func tabContent(_ tab: RouterHostTabView<R>, scope: RouterScope<R>) -> some TabContent<RouterScopeID?> {
        Tab(value: Optional(tab.id), role: tab.role.swiftUITabRole) {
            tab.content.render(scope).routerAuthority(scope, for: R.self)
        } label: {
            tab.label(scope).routerAuthority(scope, for: R.self)
        }
    }

    private var selection: Binding<RouterScopeID?> {
        Binding(get: { scope.observedSelection }, set: { id in
            if let id { scope.dispatch(.select(id), context: .init(source: .system)) }
        })
    }
}
