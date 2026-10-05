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

    @Test("Stale restored branches reject before commit, then explicit reconciliation preserves them")
    func staleRestoredBranchesRequireReconciliation() async throws {
        let store = try makeTabStore(initial: .home, orphanPolicy: .preserveDormant)
        let initial = store.state
        let catalog = try RouterTabCatalog(RouterTabHostRoute.routerTabs)
        let drifted = try RouterState<RouterTabHostRoute>(root: .container(.init(
            style: .tabs,
            selection: "legacySettings",
            branches: [
                RouterBranch(id: "home"),
                RouterBranch(id: "inbox"),
                RouterBranch(id: "legacySettings", node: .stack(path: [.settings])),
            ]
        )))
        guard case .rejected(_, _, _, .hostContract(let failure)) =
            await store.perform(.apply(.init(state: drifted))) else {
            Issue.record("Expected missing current tab to reject before commit")
            return
        }
        #expect(failure.code == .missingBranch)
        #expect(failure.scope == ["settings"])
        #expect(store.state == initial)
        #expect(store.revision == 0)

        let reconciled = try RouterTabRestorationTopology(catalog: catalog).reconciling(drifted)
        guard case .applied = await store.perform(.apply(.init(state: reconciled))) else {
            Issue.record("Expected explicitly reconciled state to apply")
            return
        }
        let recorder = RouterTabHostRecorder()
        let host = try RouterTabHost(store: store, orphanPolicy: .preserveDormant)
            .environment(recorder)
        _ = try renderRouterTabHost(host)
        await drainMainActorTasks()
        #expect(store.state.node(at: ["legacySettings"]) == .stack(path: [.settings]))
        #expect(recorder.appearances.contains(.home))
    }

    @Test("A reconciled orphan selection sends links to the explicitly selected rendered tab")
    func orphanedSelectionLinkTargetsReconciledTab() async throws {
        let snapshot = try RouterState<RouterTabLinkRoute>(root: .container(.init(
            style: .tabs,
            selection: "legacy",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "inbox"), RouterBranch(id: "legacy")]
        )))
        let catalog = try RouterTabCatalog(RouterTabLinkRoute.routerTabs)
        let configuration = RouterStoreConfiguration<RouterTabLinkRoute>(hostDescriptor: .init(
            root: catalog.hostShape(orphanPolicy: .preserveDormant)
        ))
        expectTabHostFailure(.selectionNotRendered) {
            _ = try RouterStore(initialState: snapshot, configuration: configuration)
        }
        let reconciled = try RouterTabRestorationTopology(catalog: catalog).reconciling(snapshot)
        let store = try RouterStore(initialState: reconciled, configuration: configuration)
        let host = try RouterTabHost(store: store, orphanPolicy: .preserveDormant)
        #expect(host.displayedSelection(for: "home") == "home")
        #expect(host.displayedSelection(for: nil) == nil)
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

    @Test(
        "Tab host construction and links explicitly reject another declared root shape",
        arguments: [RouterContainerStyle.split, .custom("wizard")]
    )
    func mismatchedRootRejectsHostWrites(style: RouterContainerStyle) throws {
        let split: RouterSplitState? = style == .split
            ? try RouterSplitState(sidebar: "home", detail: "inbox") : nil
        let restored = try RouterState<RouterTabLinkRoute>(root: .container(.init(
            style: style, selection: "inbox",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "inbox")], split: split
        )))
        let actualShape: RouterHostShape = style == .split
            ? .splitTwo(sidebar: .init("home", shape: .stack), detail: .init("inbox", shape: .stack))
            : .custom(declarationID: "wizard", branches: [
                .init("home", shape: .stack), .init("inbox", shape: .stack),
            ], extras: .reject)
        let store = try RouterStore(initialState: restored, configuration: .init(hostDescriptor: .init(root: actualShape)))
        expectTabHostFailure(.rendererMismatch) { _ = try RouterTabHost(store: store) }

        // A fully admitted tabs host is a positive control, so link rejection
        // cannot be caused by missing configuration or a failed constructor.
        let host = try RouterTabHost(RouterTabLinkRoute.self, initial: .home)
        expectTabHostFailure(.kindMismatch) { _ = try host.defaultLinkPlan(.detail, restored) }
        expectTabHostFailure(.kindMismatch) { _ = try host.defaultLinkPlan(.home, restored) }
        #expect(store.state == restored)
        #expect(store.revision == 0)
    }

    @Test("A tab host reports a typed failure for an explicitly declared stack root")
    func nonTabRootRejectsWithoutMutation() throws {
        let restored = RouterState<RouterTabHostRoute>.rootStack(path: [.settings])
        let store = try RouterStore(initialState: restored, configuration: .init(hostDescriptor: .init(root: .stack)))
        expectTabHostFailure(.rendererMismatch) { _ = try RouterTabHost(store: store) }
        #expect(store.state == restored)
        #expect(store.revision == 0)
        let stackHost = RouterHost(store: store) { Text("Stack root") }
        #expect(stackHost.validationFailure == nil)
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
    badges: [RouterTabHostRoute.Tab: Int] = [:],
    orphanPolicy: RouterHostOrphanPolicy = .reject
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
    let catalog = try RouterTabCatalog(tabs)
    return try RouterStore(
        initialState: try RouterState(root: .container(container)),
        configuration: .init(hostDescriptor: .init(root: catalog.hostShape(orphanPolicy: orphanPolicy)))
    )
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

@MainActor
private func expectTabHostFailure(
    _ code: RouterHostValidationFailure.Code,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected a typed host validation failure")
    } catch let failure as RouterHostValidationFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("Expected host validation failure, received \(type(of: error))")
    }
}
