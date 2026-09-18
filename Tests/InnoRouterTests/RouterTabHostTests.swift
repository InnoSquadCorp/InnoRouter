#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum RouterTabHostRoute: String, Codable, DestinationRoute, RouterTabRoute {
    case home
    case inbox
    case settings
    case detail

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
        case .detail: "Detail"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .inbox: "tray"
        case .settings: "gearshape"
        case .detail: "doc.text"
        }
    }

    static func destination(for route: Self) -> some View {
        RouterTabDestination(route: route)
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
private final class RouterTabRestorationPolicyRecorder {
    var proposedContainer: RouterContainerState<RouterTabHostRoute>?
}

private struct RouterTabSnapshotStorage: RouterSnapshotStorage {
    let data: Data

    func load() throws -> Data? { data }
    func save(_ data: Data) throws {}
    func remove() throws {}
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

    // Ordinary exact plans remain exact even when the caller applies an old
    // topology directly. The host must not crash, but restoration is the
    // boundary that makes current tabs navigable.
    @Test("RouterTabHost renders an exact plan whose branches predate a tab rename")
    func staleExactPlanDoesNotAbort() async throws {
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

        // Exact application keeps the caller's topology and the orphaned
        // branch. It does not silently turn a plan into a restoration repair.
        #expect(tabContainer(in: store)?.branches.contains { $0.id == "legacySettings" } == true)
        #expect(store.scope(at: ["settings"]).node == nil)
        #expect(recorder.appearances.contains(.home))
    }

    @Test("Snapshot restoration reconciles stale tabs before policy and commit")
    func snapshotRestorationReconcilesTabs() async throws {
        let codec = try RouterSnapshotCodec<RouterTabHostRoute>(currentVersion: 1)
        let drifted = try makeDriftedTabState()
        let data = try codec.encode(drifted)
        let policyRecorder = RouterTabRestorationPolicyRecorder()
        var configuration = RouterStoreConfiguration<RouterTabHostRoute>()
        configuration.policies = [
            RouterPolicy(name: "observe-restored-tabs") { transition in
                if case .container(let container) = transition.proposedState.root {
                    policyRecorder.proposedContainer = container
                }
                return .allow
            },
        ]
        let store = try makeTabStore(initial: .home, configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: RouterTabSnapshotStorage(data: data)
        )

        guard case .restored(let restoration) = try await driver.activate(),
              case .applied(_, _, let restored, 1) = restoration.transition,
              case .restored(let decoded) = restoration.decoding,
              case .container(let container) = restored.root else {
            Issue.record("Expected one reconciled restoration commit")
            return
        }

        let expectedIDs: [RouterScopeID] = ["home", "inbox", "settings", "legacySettings"]
        #expect(policyRecorder.proposedContainer?.branches.map(\.id) == expectedIDs)
        #expect(policyRecorder.proposedContainer?.selection == "home")
        #expect(container.branches.map(\.id) == expectedIDs)
        #expect(container.selection == "home")
        #expect(container.badges == ["home": 2, "legacySettings": 7])
        #expect(container.branches[0].node == .stack(path: [.detail]))
        #expect(container.branches[1].node == .stack(path: [.inbox]))
        #expect(container.branches[2].node == .stack())
        #expect(container.branches[3].node == .stack(path: [.settings]))
        #expect(decoded == drifted)
        #expect(store.state == restored)

        guard case .applied = await store.perform(.select("settings")),
              case .applied = await store.scope(at: ["settings"]).perform(.push(.detail)) else {
            Issue.record("Expected the restored current tab to remain navigable")
            return
        }
        #expect(store.scope(at: ["settings"]).node == .stack(path: [.detail]))

        let recorder = RouterTabHostRecorder()
        _ = try renderRouterTabHost(
            RouterTabHost(store: store).environment(recorder)
        )
        await drainMainActorTasks()
        #expect(recorder.paths.contains([.detail]))

        let saved = try await store.snapshot(using: codec)
        let reopened = try makeTabStore(initial: .home)
        guard case .applied = try await reopened.restore(from: saved, using: codec) else {
            Issue.record("Expected the reconciled snapshot to restore again")
            return
        }
        #expect(reopened.state == store.state)
        driver.stop()
    }

    @Test("Partial restoration uses the same current tab topology")
    func partialRestorationReconcilesTabs() async throws {
        let codec = try RouterSnapshotCodec<RouterTabHostRoute>(currentVersion: 1)
        let data = try codec.encode(makeDriftedTabState())
        let store = try makeTabStore(initial: .home)

        let outcome = try await store.restorePartially(
            from: data,
            using: codec,
            validator: .init { _, _ in .keep }
        )

        guard case .applied(_, _, let restored, 1) = outcome.transition,
              case .container(let container) = restored.root else {
            Issue.record("Expected one reconciled partial-restoration commit")
            return
        }
        #expect(container.branches.map(\.id) == [
            "home", "inbox", "settings", "legacySettings",
        ])
        #expect(container.selection == "home")
        #expect(outcome.report.entries.allSatisfy { $0.change == .kept })
    }

    @Test("A policy rejection preserves the current tab topology and revision")
    func policyRejectsReconciledTabsAtomically() async throws {
        let codec = try RouterSnapshotCodec<RouterTabHostRoute>(currentVersion: 1)
        let data = try codec.encode(makeDriftedTabState())
        var configuration = RouterStoreConfiguration<RouterTabHostRoute>()
        configuration.policies = [
            RouterPolicy(name: "tab-restore-lock") { transition in
                guard case .container(let container) = transition.proposedState.root,
                      container.branches.contains(where: { $0.id == "settings" }),
                      container.selection == "home" else {
                    return .reject("candidate-was-not-reconciled")
                }
                return .reject("locked")
            },
        ]
        let store = try makeTabStore(initial: .home, configuration: configuration)
        let before = store.state

        let outcome = try await store.restore(from: data, using: codec)

        guard case .rejected(_, let state, 0, let reason) = outcome else {
            Issue.record("Expected policy to reject the reconciled candidate")
            return
        }
        #expect(reason == .policy(name: "tab-restore-lock", message: "locked"))
        #expect(state == before)
        #expect(store.state == before)
        #expect(store.revision == 0)
    }

    @Test("Restoration rejects a root shape incompatible with the current tab host")
    func restorationRejectsIncompatibleRootShape() async throws {
        let codec = try RouterSnapshotCodec<RouterTabHostRoute>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.detail]))
        let store = try makeTabStore(initial: .home)

        await #expect(throws: RouterMutationError.incompatibleNavigationTopology(.root)) {
            try await store.restore(from: data, using: codec)
        }
        #expect(store.revision == 0)
        #expect(tabContainer(in: store)?.selection == "home")
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
    configuration: RouterStoreConfiguration<RouterTabHostRoute> = .init()
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
    return RouterStore(
        initialState: try RouterState(root: .container(container)),
        configuration: configuration
    )
}

private func makeDriftedTabState() throws -> RouterState<RouterTabHostRoute> {
    let drifted = try RouterContainerState<RouterTabHostRoute>(
        style: .tabs,
        selection: "legacySettings",
        branches: [
            RouterBranch(id: "home", node: .stack(path: [.detail])),
            RouterBranch(id: "inbox", node: .stack(path: [.inbox])),
            RouterBranch(id: "legacySettings", node: .stack(path: [.settings])),
        ],
        badges: ["home": 2, "legacySettings": 7]
    )
    return try RouterState(root: .container(drifted))
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
