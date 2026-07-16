import Foundation
import SwiftUI

import InnoRouter

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum ExternalRoute {
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

@Router
enum ExternalTab {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
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

private struct ExternalActions: View {
    @EnvironmentRouter(ExternalRoute.self) private var router

    var body: some View {
        Button("Route") {
            router.go(.detail(id: "42"))
            router.sheet(.settings)
            router.dismiss()
            router.back()
        }
    }
}

@MainActor
public enum MacroFirstConsumerProbe {
    public static func exercise() {
        _ = RouterHost(ExternalRoute.self) {
            ExternalActions()
        }.body

        _ = RouterModalHost(ExternalRoute.self) {
            ExternalActions()
        }.body

#if !os(watchOS)
        _ = RouterSplitHost(ExternalRoute.self) {
            Text("Sidebar")
        } root: {
            ExternalActions()
        }.body
#endif

        _ = RouterTabHost(ExternalTab.self, initial: .home).body

        if let url = URL(string: "innorouter://app.example.com/details/42") {
            let _: ExternalRoute? = ExternalRoute.resolveDeepLink(url)
        }
    }
}
