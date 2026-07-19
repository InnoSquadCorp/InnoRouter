import Foundation
import Synchronization

import InnoRouter
import InnoRouterEffects

// Compiler-stable smoke fixture for SampleAppExample.swift.
// The dedicated MacrosSmoke target covers downstream macro expansion.

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
            originPolicy: .allowlisted(
                schemes: ["app"],
                hosts: ["sample"]
            ),
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
