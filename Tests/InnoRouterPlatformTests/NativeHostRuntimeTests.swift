import SwiftUI
import Testing
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

import InnoRouterCore
import InnoRouterSwiftUI

private enum NativeHostRoute: DestinationRoute, RouterTabRoute {
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
#endif
}
