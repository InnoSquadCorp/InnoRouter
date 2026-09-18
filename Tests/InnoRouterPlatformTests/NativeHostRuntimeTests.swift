import SwiftUI
import Testing
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

import InnoRouterCore
import InnoRouterSwiftUI

private enum NativeHostRoute: Codable, DestinationRoute, RouterTabRoute {
    case home
    case settings
    case detail

    enum Tab: String, RouterTab {
        case home
        case settings

        var title: LocalizedStringResource {
            switch self {
            case .home: "Home"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .settings: "gearshape"
            }
        }

        var routerScopeID: RouterScopeID { RouterScopeID(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home),
        .init(tab: .settings, root: .settings),
    ]

    @MainActor
    static func destination(for route: Self) -> some View {
        Text(verbatim: String(describing: route))
    }
}

@Suite("Native host runtime", .tags(.unit))
@MainActor
struct NativeHostRuntimeTests {
    @Test("Snapshot restoration makes every current tab navigable")
    func tabRestorationUsesCurrentTopology() async throws {
        let baseline = try RouterContainerState<NativeHostRoute>(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "settings")]
        )
        let store = RouterStore(
            initialState: try RouterState(root: .container(baseline))
        )
        let legacy = try RouterContainerState<NativeHostRoute>(
            style: .tabs,
            selection: "legacySettings",
            branches: [
                RouterBranch(id: "home", node: .stack(path: [.detail])),
                RouterBranch(id: "legacySettings", node: .stack(path: [.settings])),
            ]
        )
        let codec = try RouterSnapshotCodec<NativeHostRoute>(currentVersion: 1)
        let data = try codec.encode(
            try RouterState(root: .container(legacy))
        )

        guard case .applied = try await store.restore(from: data, using: codec),
              case .applied = await store.perform(.select("settings")),
              case .applied = await store.scope(at: ["settings"]).perform(.push(.detail)) else {
            Issue.record("Expected restored current tabs to remain navigable")
            return
        }
        guard case .container(let restored) = store.state.root else {
            Issue.record("Expected a restored tab container")
            return
        }
        #expect(restored.selection == "settings")
        #expect(restored.branches.map(\.id) == ["home", "settings", "legacySettings"])
        #expect(store.scope(at: ["settings"]).node == .stack(path: [.detail]))
    }

    @Test("Stack, tab, and presentation hosts evaluate on the running platform")
    func nativeHostBodies() async throws {
        let stackStore = RouterStore<NativeHostRoute>()
        let stackHost = RouterHost(store: stackStore) {
            Text(verbatim: "Root")
        }
        _ = stackHost.body

        let catalog = try RouterTabCatalog(NativeHostRoute.routerTabs)
        let tabHost = try RouterTabHost(
            NativeHostRoute.self,
            catalog: catalog,
            initial: .home
        )
        _ = tabHost.body

        _ = await stackStore.perform(
            .present(.init(route: .detail, style: .sheet)),
            context: .init(source: .system)
        )
        _ = stackHost.body
        guard case .stack(let stack) = stackStore.state.root else {
            Issue.record("Expected native stack state")
            return
        }
        #expect(stack.presentation?.route == .detail)
    }

#if canImport(UIKit) && !os(watchOS)
    @Test("UIHostingController mounts the canonical stack host")
    func uiKitStackMount() async {
        let store = RouterStore<NativeHostRoute>()
        let controller = UIHostingController(
            rootView: RouterHost(store: store) {
                Text(verbatim: "Root")
            }
        )

        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        _ = await store.perform(.push(.detail))

        #expect(controller.viewIfLoaded != nil)
        #expect(store.state.root == .stack(path: [.detail]))
    }

    @Test("UIHostingController mounts canonical tab selection")
    func uiKitTabMount() async throws {
        let catalog = try RouterTabCatalog(NativeHostRoute.routerTabs)
        let container = try RouterContainerState<NativeHostRoute>(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "settings")]
        )
        let store = RouterStore(
            initialState: try RouterState(root: .container(container))
        )
        let controller = UIHostingController(
            rootView: try RouterTabHost(store: store, catalog: catalog)
        )

        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        _ = await store.perform(
            .select("settings"),
            context: .init(source: .system)
        )

        #expect(controller.viewIfLoaded != nil)
        guard case .container(let updated) = store.state.root else {
            Issue.record("Expected native tab container")
            return
        }
        #expect(updated.selection == "settings")
    }

    @Test("UIHostingController mounts a reconciled restored tab tree")
    func uiKitRestoredTabMount() async throws {
        let baseline = try RouterContainerState<NativeHostRoute>(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "settings")]
        )
        let store = RouterStore(
            initialState: try RouterState(root: .container(baseline))
        )
        let legacy = try RouterContainerState<NativeHostRoute>(
            style: .tabs,
            selection: "legacySettings",
            branches: [
                RouterBranch(id: "home"),
                RouterBranch(id: "legacySettings", node: .stack(path: [.settings])),
            ]
        )
        let codec = try RouterSnapshotCodec<NativeHostRoute>(currentVersion: 1)
        let data = try codec.encode(
            try RouterState(root: .container(legacy))
        )
        _ = try await store.restore(from: data, using: codec)
        let controller = UIHostingController(rootView: RouterTabHost(store: store))

        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        _ = await store.perform(.select("settings"))
        _ = await store.scope(at: ["settings"]).perform(.push(.detail))

        #expect(controller.viewIfLoaded != nil)
        #expect(store.scope(at: ["settings"]).node == .stack(path: [.detail]))
    }
#endif
}
