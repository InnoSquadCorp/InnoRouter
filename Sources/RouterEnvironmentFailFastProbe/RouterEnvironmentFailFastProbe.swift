import SwiftUI

import InnoRouterCore
import InnoRouterSwiftUI

private enum ProbeRoute: Route {
    case root
}

private struct ProbeView: View {
    @EnvironmentRouter(ProbeRoute.self) private var router

    var body: some View {
        // Intentionally triggers fail-fast when host injection is missing.
        router.go(.root)
        return EmptyView()
    }
}

@MainActor
@main
struct RouterEnvironmentFailFastProbe {
    static func main() {
        _ = ProbeView().body
    }
}
