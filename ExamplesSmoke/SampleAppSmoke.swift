import Foundation
import Synchronization

import InnoRouter
import InnoRouterDeepLink
import InnoRouterEffects

// Compiler-stable smoke fixture for SampleAppExample.swift.
// The human-facing example uses `@Routable` (which lives in the
// macros target). The smoke target avoids the macro plugin so it
// compiles uniformly across every platform CI leg.

private enum SampleSmokeRoute: Route {
    case home
    case detail(id: String)
    case profile
}

@MainActor
private final class SampleSmokeAuthority {
    let store = NavigationStore<SampleSmokeRoute>()
    let modal = ModalStore<SampleSmokeRoute>()
    let flow = FlowStore<SampleSmokeRoute>()
    let debouncedSearch: DebouncingNavigator<NavigationStore<SampleSmokeRoute>, ContinuousClock>
    private let session = SmokeSession()

    init() {
        self.debouncedSearch = DebouncingNavigator(
            wrapping: store,
            interval: .milliseconds(250)
        )
    }

    var pipeline: DeepLinkPipeline<SampleSmokeRoute> {
        DeepLinkPipeline(
            allowedSchemes: ["app"],
            allowedHosts: ["sample"],
            customResolver: { url in
                switch url.path {
                case "/profile": .profile
                default:         nil
                }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .profile },
                isAuthenticated: { [session] in session.isAuthenticated }
            )
        )
    }
}

private final class SmokeSession: Sendable {
    private let storage: Mutex<Bool>
    init() { self.storage = Mutex(false) }
    var isAuthenticated: Bool {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
