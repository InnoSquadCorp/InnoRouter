import SwiftUI

import InnoRouterCore

extension EnvironmentValues {
    @Entry var routerEnvironment: RouterEnvironment?
}

extension View {
    /// Publishes one stable read-only scope from the canonical store.
    @MainActor
    func routerAuthority<R: Route>(
        _ scope: RouterScope<R>,
        for routeType: R.Type
    ) -> some View {
        transformEnvironment(\.routerEnvironment) { environment in
            var resolved = environment ?? RouterEnvironment()
            resolved.register(RouterAuthority(scope: scope), for: routeType)
            environment = resolved
        }
    }
}
