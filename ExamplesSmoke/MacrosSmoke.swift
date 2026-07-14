import SwiftUI

import InnoRouter

@Router
enum RouterMacroSmokeRoute {
    case settings

    var destination: some View {
        Text("Settings")
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
            Text("Root")
        }
        _ = routerHost.body

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
