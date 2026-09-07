import Foundation
import SwiftUI

import InnoRouter

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum RouterMacroSmokeRoute: Codable {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    @PresentationResult(Bool.self)
    case settings

    @DeepLink("/details/:id")
    case detail(id: String)

    @Scene(.window, id: "editor")
    case editor

    var destination: some View {
        switch self {
        case .home:
            RouterMacroSmokeActions()
        case .settings:
            Text("Settings")
        case .detail(let id):
            Text("Detail \(id)")
        case .editor:
            Text("Editor")
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
            router.dismiss()
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
}

@CasePathable
enum MacrosSmokeEvent {
    case tapped
    case opened(id: String)
}

@MainActor
enum MacrosSmokeConsumer {
    static func exercise() async throws {
        _ = RouterHost(RouterMacroSmokeRoute.self) {
            RouterMacroSmokeActions()
        }.body

#if !os(watchOS)
        _ = RouterSplitHost(RouterMacroSmokeRoute.self) {
            Text("Sidebar")
        } root: {
            RouterMacroSmokeActions()
        }.body
#endif

        _ = RouterTabHost(
            RouterMacroSmokeRoute.self,
            initial: .home,
            badges: [.settings: 1]
        ).body

        let store = RouterMacroSmokeRoute.makeRouterStore()
        _ = await store.perform(.push(.detail(id: "42")))

        let request = RouterMacroSmokeRoute.Presentation.settings
        let presentation = Task { @MainActor in await store.present(request) }
        await Task.yield()
        try await store.finishPresentation(request, returning: true)
        _ = await presentation.value

        _ = try await store.transaction {
            RouterPlanStep.stack([.home, .detail(id: "plan")])
            RouterPlanStep.action(.openWindow(.init(route: .editor)))
        }

        _ = RouterMacroSmokeRoute.routerScenes

        let origin = DeepLinkOrigin(scheme: "https", host: "app.example.com")!
        _ = RouterOpenURLIntentBuilder<RouterMacroSmokeRoute>(origin: origin)
            .intent(for: .detail(id: "42"))

        let codec = try RouterSnapshotCodec<RouterMacroSmokeRoute>(currentVersion: 1)
        let snapshot = try await store.snapshot(using: codec)
        _ = try await store.restore(from: snapshot, using: codec)

        if let url = URL(string: "innorouter://app.example.com/details/42") {
            let _: RouterMacroSmokeRoute? = RouterMacroSmokeRoute.resolveDeepLink(url)
        }

        let route = MacrosSmokeRoute.detail(id: "42")
        let _: Bool = route.is(MacrosSmokeRoute.Cases.detail)
        let _: String? = route[case: MacrosSmokeRoute.Cases.detail]

        let event = MacrosSmokeEvent.opened(id: "evt-1")
        let _: Bool = event.is(MacrosSmokeEvent.Cases.opened)
        let _: String? = event[case: MacrosSmokeEvent.Cases.opened]
    }
}
