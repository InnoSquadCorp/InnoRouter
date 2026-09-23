#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum RouterTabHostRoute: String, DestinationRoute, RouterTabRoute {
    case home
    case inbox
    case settings

    enum Tab: String, RouterTab {
        case home
        case inbox
        case settings

        var title: LocalizedStringResource {
            switch self {
            case .home: "Home"
            case .inbox: "Inbox"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .inbox: "tray"
            case .settings: "gearshape"
            }
        }

        var routerScopeID: RouterScopeID { RouterScopeID(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home),
        .init(tab: .inbox, root: .inbox),
        .init(tab: .settings, root: .settings),
    ]

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .inbox: "Inbox"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .inbox: "tray"
        case .settings: "gearshape"
        }
    }

    static func destination(for route: Self) -> some View {
        RouterTabDestination(route: route)
    }
}

private enum RouterTabLinkRoute: String, DestinationRoute, RouterTabRoute {
    case home
    case inbox
    case detail

    enum Tab: String, RouterTab {
        case home
        case inbox

        var title: LocalizedStringResource { self == .home ? "Home" : "Inbox" }
        var systemImage: String { self == .home ? "house" : "tray" }
        var routerScopeID: RouterScopeID { RouterScopeID(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home),
        .init(tab: .inbox, root: .inbox),
    ]

    static func destination(for route: Self) -> some View {
        RouterTabLinkDestination(route: route)
    }
}

@MainActor
@Observable
private final class RouterTabLinkRecorder {
    var pushAttempts = 0
}

// A tab root that navigates from its own content once, as an app would.
@MainActor
private struct RouterTabLinkDestination: View {
    @EnvironmentRouter(RouterTabLinkRoute.self) private var router
    @Environment(RouterTabLinkRecorder.self) private var recorder: RouterTabLinkRecorder?

    let route: RouterTabLinkRoute

    var body: some View {
        Text(route.rawValue)
            .onAppear {
                guard let recorder, route != .detail, recorder.pushAttempts == 0 else { return }
                recorder.pushAttempts += 1
                router.go(.detail)
            }
    }
}

@MainActor
@Observable
private final class RouterTabHostRecorder {
    var appearances: [RouterTabHostRoute] = []
    @ObservationIgnored
    var paths: [[RouterTabHostRoute]] = []
    var didDispatch = false
}

@MainActor
private struct RouterTabDestination: View {
    @EnvironmentRouter(RouterTabHostRoute.self) private var router
    @EnvironmentRouterState(RouterTabHostRoute.self) private var routerState
    @Environment(RouterTabHostRecorder.self) private var recorder

    let route: RouterTabHostRoute

    var body: some View {
        Text(route.title)
#if canImport(AppKit)
            .background(RouterTabStateCapture(path: routerState.path, recorder: recorder))
#endif
            .onAppear {
                recorder.appearances.append(route)
                guard route == .home, !recorder.didDispatch else { return }
                recorder.didDispatch = true
                router.select(.inbox)
                router.setBadge(4, for: .settings)
            }
    }
}

#if canImport(AppKit)
private struct RouterTabStateCapture: NSViewRepresentable {
    let path: [RouterTabHostRoute]
    let recorder: RouterTabHostRecorder

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        recorder.paths.append(path)
    }
}
#endif

@Suite("RouterTabHost", .tags(.unit))
@MainActor
struct RouterTabHostTests {
    @Test("Manual tab catalogs fail with typed validation errors")
    func manualCatalogValidation() throws {
        #expect(throws: RouterTabCatalogError.empty) {
            try RouterTabCatalog<RouterTabHostRoute>([])
        }
        #expect(throws: RouterTabCatalogError.duplicateTabIdentity) {
            try RouterTabCatalog<RouterTabHostRoute>([
                .init(tab: .home, root: .home),
                .init(tab: .home, root: .inbox),
            ])
        }
        #expect(throws: RouterTabCatalogError.duplicateRootRoute) {
            try RouterTabCatalog<RouterTabHostRoute>([
                .init(tab: .home, root: .home),
                .init(tab: .inbox, root: .home),
            ])
        }

        let catalog = try RouterTabCatalog(RouterTabHostRoute.routerTabs)
        _ = try RouterTabHost(
            RouterTabHostRoute.self,
            catalog: catalog,
            initial: .home
        )
    }

    @Test("RouterStore owns selection and normalized badge state")
    func stateOwnership() async throws {
        let store = try makeTabStore(
            initial: .home,
            badges: [.inbox: 2, .settings: 0]
        )

        _ = await store.perform(.select("settings"))
        _ = await store.perform(.setBadge(5, for: "home"))
        _ = await store.perform(.setBadge(0, for: "inbox"))

        let container = try #require(tabContainer(in: store))
        #expect(container.selection == "settings")
        #expect(container.badges == ["home": 5])

        _ = await store.perform(.clearAllBadges)
        #expect(tabContainer(in: store)?.badges.isEmpty == true)
    }

    @Test("RouterActions maps tab methods to the canonical root scope")
    func routerActionMapping() async throws {
        let store = try makeTabStore(initial: .home)
        let router = RouterActions(
            authority: RouterAuthority(scope: store.scope())
        )

        router.select(.inbox)
        router.setBadge(3, for: .inbox)
        router.setBadge(-1, for: .settings)
        await drainMainActorTasks()

        var container = try #require(tabContainer(in: store))
        #expect(container.selection == "inbox")
        #expect(container.badges == ["inbox": 3])

        router.clearBadge(for: .inbox)
        await drainMainActorTasks()
        container = try #require(tabContainer(in: store))
        #expect(container.badges.isEmpty)
    }

    @Test("RouterTabHost renders and publishes one store authority")
    func hostConstructionAndAuthority() async throws {
        let store = try makeTabStore(initial: .home)
        let recorder = RouterTabHostRecorder()
        let catalog = try RouterTabCatalog(RouterTabHostRoute.routerTabs)
        let host = try RouterTabHost(store: store, catalog: catalog)
            .environment(recorder)

        _ = try renderRouterTabHost(host)
        await drainMainActorTasks()

        #expect(recorder.didDispatch)
        #expect(recorder.appearances.contains(.home))
        #expect(tabContainer(in: store)?.selection == "inbox")
        #expect(tabContainer(in: store)?.badges == ["settings": 4])
    }

    // A snapshot written before a tab was renamed decodes into a store whose
    // branches no longer match the catalog. `RouterRestorationDriver` applies it
    // through `.apply`, which replaces the root wholesale, so the mismatch
    // reaches a View initializer that SwiftUI re-runs every body pass. That
    // used to abort the process; the host now renders the catalog and lets the
    // orphaned branch go unused.
    @Test("RouterTabHost renders a store whose branches predate a tab rename")
    func staleRestoredBranchesDoNotAbort() async throws {
        let store = try makeTabStore(initial: .home)

        // Stand in for a decoded snapshot: "settings" was renamed since it was
        // written, and it carries the selection.
        let drifted = try RouterContainerState<RouterTabHostRoute>(
            style: .tabs,
            selection: "legacySettings",
            branches: [
                RouterBranch(id: "home", node: .stack(path: [])),
                RouterBranch(id: "inbox", node: .stack(path: [])),
                RouterBranch(id: "legacySettings", node: .stack(path: [.settings])),
            ]
        )
        let outcome = await store.perform(
            .apply(RouterPlan(state: try RouterState(root: .container(drifted))))
        )
        guard case .applied = outcome else {
            Issue.record("Expected the drifted snapshot to apply")
            return
        }

        let recorder = RouterTabHostRecorder()
        let host = RouterTabHost(store: store)
            .environment(recorder)

        _ = try renderRouterTabHost(host)
        await drainMainActorTasks()

        // The orphaned branch is still in the state; the host simply does not
        // render it, and the catalog's own tabs remain reachable.
        #expect(tabContainer(in: store)?.branches.contains { $0.id == "legacySettings" } == true)
        #expect(recorder.appearances.contains(.home))
    }

    // The host displays its first tab for a restored selection the catalog no
    // longer declares. A link it pushes must land in that displayed tab rather
    // than in the hidden branch, and it selects that tab in the same plan.
    @Test("A link under an orphaned restored selection lands in the displayed tab")
    func orphanedSelectionLinkTargetsDisplayedTab() async throws {
        let store = RouterStore<RouterTabLinkRoute>(
            initialState: try RouterState(root: .container(.init(
                style: .tabs,
                selection: "legacy",
                branches: [
                    RouterBranch(id: "home"),
                    RouterBranch(id: "inbox"),
                    RouterBranch(id: "legacy"),
                ]
            )))
        )
        let host = RouterTabHost(store: store)
        #expect(host.displayedSelection(for: "legacy") == "home")
        #expect(host.displayedSelection(for: nil) == "home")
        #expect(host.displayedSelection(for: "inbox") == "inbox")

        let plan = try host.defaultLinkPlan(.detail, store.state)
        guard case .applied = await store.perform(.apply(plan)) else {
            Issue.record("Expected the default link plan to apply")
            return
        }

        guard case .container(let container) = store.state.root else {
            Issue.record("Expected the tabs root to remain")
            return
        }
        #expect(container.selection == "home")
        #expect(store.state.node(at: ["home"]) == .stack(path: [.detail]))
        #expect(store.state.node(at: ["legacy"]) == .stack())
    }

    // A split or custom root can carry branches named like tabs. The host
    // renders over such a root without owning its topology, so neither its
    // default links, a tab bar selection, nor navigation from a tab's own
    // content may write into those branches.
    @Test(
        "Links, tab selection, and tab content never write into a root of another shape",
        arguments: [RouterContainerStyle.split, .custom("wizard")]
    )
    func mismatchedRootRejectsHostWrites(style: RouterContainerStyle) async throws {
        var split: RouterSplitState?
        if style == .split {
            split = try RouterSplitState(sidebar: "home", detail: "inbox")
        }
        let restored = try RouterState<RouterTabLinkRoute>(root: .container(.init(
            style: style,
            selection: "inbox",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "inbox")],
            split: split
        )))
        let store = RouterStore(initialState: restored)
        let host = RouterTabHost(store: store)

        #expect(throws: RouterMutationError.incompatibleNavigationTopology(.root)) {
            try host.defaultLinkPlan(.detail, store.state)
        }
        #expect(throws: RouterMutationError.incompatibleNavigationTopology(.root)) {
            try host.defaultLinkPlan(.home, store.state)
        }
        host.requestSelection("home", in: store.scope())
        let recorder = RouterTabLinkRecorder()
        _ = try renderRouterTabHost(host.environment(recorder))
        await drainMainActorTasks()

        #expect(recorder.pushAttempts == 1)
        #expect(store.state == restored)
        #expect(store.revision == 0)
    }

    // Exact restoration may replace the root with any valid shape, such as a
    // stack written before the application adopted tabs. SwiftUI re-runs this
    // initializer on every parent body pass, so it must not trap on that data.
    @Test("RouterTabHost renders its catalog over a store whose root is not tabs")
    func nonTabRootDoesNotAbort() async throws {
        let restored = RouterState<RouterTabHostRoute>.rootStack(path: [.settings])
        let store = RouterStore(initialState: restored)
        let recorder = RouterTabHostRecorder()
        let host = RouterTabHost(store: store)
            .environment(recorder)

        _ = try renderRouterTabHost(host)
        await drainMainActorTasks()

        #expect(recorder.appearances.contains(.home))
        // The host renders; it never rewrites the application's state.
        #expect(store.state == restored)
    }

    @Test("RouterTabHost follows replacement application-owned stores")
    func externalStoreReplacement() async throws {
#if canImport(AppKit)
        let catalog = try RouterTabCatalog(RouterTabHostRoute.routerTabs)
        let first = try makeTabStore(initial: .home)
        let second = try makeTabStore(initial: .home)
        let firstRecorder = RouterTabHostRecorder()
        let secondRecorder = RouterTabHostRecorder()
        let initial = try RouterTabHost(store: first, catalog: catalog)
            .environment(firstRecorder)
        let hostingView = try renderRouterTabHost(initial)
        await drainMainActorTasks()
        _ = await first.perform(.select("home"))
        _ = await second.perform(.push(.settings).inScope("home"))

        hostingView.rootView = try RouterTabHost(store: second, catalog: catalog)
            .environment(secondRecorder)
        await renderRouterTabHostReplacement(hostingView)
        await drainMainActorTasks()

        #expect(tabContainer(in: first)?.selection == "home")
        #expect(secondRecorder.paths.contains([.settings]))
#else
        throw Skip("RouterTabHost replacement rendering requires AppKit.")
#endif
    }
}

@MainActor
private func makeTabStore(
    initial: RouterTabHostRoute.Tab,
    badges: [RouterTabHostRoute.Tab: Int] = [:]
) throws -> RouterStore<RouterTabHostRoute> {
    let tabs = RouterTabHostRoute.routerTabs
    let pairs: [(RouterScopeID, Int)] = badges.compactMap { tab, count in
        count > 0 ? (tab.routerScopeID, count) : nil
    }
    let container = try RouterContainerState<RouterTabHostRoute>(
        style: .tabs,
        selection: initial.routerScopeID,
        branches: tabs.map { RouterBranch(id: $0.tab.routerScopeID) },
        badges: Dictionary(uniqueKeysWithValues: pairs)
    )
    return RouterStore(initialState: try RouterState(root: .container(container)))
}

@MainActor
private func tabContainer(
    in store: RouterStore<RouterTabHostRoute>
) -> RouterContainerState<RouterTabHostRoute>? {
    guard case .container(let container) = store.state.root else { return nil }
    return container
}

@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<4 { await Task.yield() }
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderRouterTabHost<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return hostingView
}

@MainActor
private func renderRouterTabHostReplacement<V: View>(
    _ hostingView: NSHostingView<V>
) async {
    hostingView.layoutSubtreeIfNeeded()
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    hostingView.layoutSubtreeIfNeeded()
}
#else
@MainActor
private func renderRouterTabHost<V: View>(_ view: V) throws {
    throw Skip("RouterTabHost rendering tests require AppKit.")
}
#endif
