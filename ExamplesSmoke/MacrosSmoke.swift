import Foundation
import SwiftUI

import InnoRouter

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum RouterMacroSmokeRoute {
    @DeepLink("/details/:id")
    case detail(id: String)

    @DeepLink("/settings")
    case settings

    var destination: some View {
        switch self {
        case .detail(let id):
            Text("Detail \(id)")
        case .settings:
            Text("Settings")
        }
    }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["app.example.com"]
)
enum RouterMacroSmokeTab {
    @TabItem("Home", systemImage: "house")
    @DeepLink("/tabs/home")
    case home

    @TabItem("Settings", systemImage: "gear")
    @DeepLink("/tabs/settings")
    case settings

    var destination: some View {
        switch self {
        case .home:
            Text("Home")
        case .settings:
            Text("Settings")
        }
    }
}

private struct RouterMacroSmokeActions: View {
    @EnvironmentRouter(RouterMacroSmokeRoute.self) private var router

    var body: some View {
        Button("Exercise route actions") {
            router.go(.detail(id: "42"))
            router.back()
            router.sheet(.settings)
            router.cover(.settings)
            router.dismissAll()
        }
    }
}

private struct RouterMacroSmokeModalActions: View {
    @EnvironmentRouter(RouterMacroSmokeRoute.self) private var router

    var body: some View {
        Button("Exercise modal actions") {
            router.sheet(.settings)
            router.dismiss()
        }
    }
}

private struct RouterMacroSmokeTabActions: View {
    @EnvironmentRouter(RouterMacroSmokeTab.self) private var router

    var body: some View {
        Button("Exercise tab actions") {
            router.select(.settings)
            router.setBadge(1, for: .settings)
            router.clearBadge(for: .settings)
            router.clearAllBadges()
        }
    }
}

@Routable
enum MacrosSmokeRoute {
    case list
    case detail(id: String)
    case preview(_ id: String, section: Int)
    case settings
}

@CasePathable
enum MacrosSmokeEvent {
    case tapped
    case opened(id: String)
    case selected(_ itemID: String)
}

@MainActor
enum MacrosSmokeConsumer {
    static func exercise() {
        let routerHost = RouterHost(RouterMacroSmokeRoute.self) {
            RouterMacroSmokeActions()
        }
        _ = routerHost.body

        let modalHost = RouterModalHost(RouterMacroSmokeRoute.self) {
            RouterMacroSmokeModalActions()
        }
        _ = modalHost.body

#if !os(watchOS)
        let splitHost = RouterSplitHost(RouterMacroSmokeRoute.self) {
            Text("Sidebar")
        } root: {
            RouterMacroSmokeActions()
        }
        _ = splitHost.body
#endif

        let tabHost = RouterTabHost(
            RouterMacroSmokeTab.self,
            initial: .home,
            badges: [.settings: 1]
        )
        _ = tabHost.body
        _ = RouterMacroSmokeTabActions().body

        if let url = URL(string: "innorouter://app.example.com/details/42") {
            let _: RouterMacroSmokeRoute? = RouterMacroSmokeRoute.resolveDeepLink(url)
        }

        let route = MacrosSmokeRoute.detail(id: "42")
        let preview = MacrosSmokeRoute.preview("99", section: 2)

        let _: Bool = route.is(MacrosSmokeRoute.Cases.detail)
        let _: Bool = route.is(MacrosSmokeRoute.Cases.list)
        let _: String? = route[case: MacrosSmokeRoute.Cases.detail]

        let _: Bool = preview.is(MacrosSmokeRoute.Cases.preview)
        let _: (String, Int)? = preview[case: MacrosSmokeRoute.Cases.preview]

        let _: MacrosSmokeRoute = MacrosSmokeRoute.Cases.detail.embed("99")
        let _: MacrosSmokeRoute = MacrosSmokeRoute.Cases.preview.embed(("preview-1", 3))

        let event = MacrosSmokeEvent.opened(id: "evt-1")
        let selected = MacrosSmokeEvent.selected("evt-2")

        let _: Bool = event.is(MacrosSmokeEvent.Cases.opened)
        let _: String? = event[case: MacrosSmokeEvent.Cases.opened]

        let _: Bool = selected.is(MacrosSmokeEvent.Cases.selected)
        let _: String? = selected[case: MacrosSmokeEvent.Cases.selected]
        let _: MacrosSmokeEvent = MacrosSmokeEvent.Cases.selected.embed("evt-3")
    }
}
