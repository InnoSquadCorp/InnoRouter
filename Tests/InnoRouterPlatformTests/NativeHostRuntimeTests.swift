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
    @Test("Nonthrowing stack hosts report a root declaration mismatch without mutation")
    func opaqueStackRootMeaning() throws {
        let store = try RouterStore<NativeHostRoute>(configuration: .init(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("app.home"))]
        )))
        let matching = RouterHost(store: store, rootDeclarationID: "app.home") { Text("Home") }
        let localized = RouterHost(store: store, rootDeclarationID: "app.home") { Text("홈") }
        let changed = RouterHost(store: store, rootDeclarationID: "app.other") { Text("Other feature") }
        #expect(matching.validationFailure == nil)
        #expect(localized.validationFailure == nil)
        #expect(changed.validationFailure?.code == .rendererMismatch)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Stack, tab, and presentation hosts evaluate on the running platform")
    func nativeHostBodies() async throws {
        let stackStore = try RouterStore<NativeHostRoute>(configuration: .init(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
        )))
        let stackHost = RouterHost(store: stackStore) {
            Text(verbatim: "Root")
        }
        #expect(stackHost.validationFailure == nil)
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
    func uiKitStackMount() async throws {
        let store = try RouterStore<NativeHostRoute>(configuration: .init(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(meaning: .declarationID("router.root"))]
        )))
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
        let store = try RouterStore(
            initialState: try RouterState(root: .container(container)),
            configuration: .init(hostDescriptor: catalog.hostDescriptor())
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
