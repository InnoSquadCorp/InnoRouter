import SwiftUI

import InnoRouter

@Routable
enum AppRoute {
    case home
    case auth
}

@Routable
enum HomeRoute {
    case dashboard
    case profile
}

@Observable
@MainActor
final class AppCoordinator: Coordinator {
    typealias RouteType = AppRoute
    typealias Destination = AppDestinationView

    let store = NavigationStore<AppRoute>()
    var isAuthenticated = false

    func handle(_ intent: NavigationIntent<AppRoute>) {
        switch intent {
        case .go(let route):
            switch route {
            case .home:
                _ = store.execute(.replace([.home]))
            case .auth:
                _ = store.execute(.replace([.auth]))
            }
        default:
            store.send(intent)
        }
    }

    @ViewBuilder
    func destination(for route: AppRoute) -> AppDestinationView {
        AppDestinationView(route: route)
    }
}

struct CoordinatorExampleView: View {
    @State private var coordinator = AppCoordinator()

    var body: some View {
        CoordinatorHost(coordinator: coordinator) {
            CoordinatorRootView()
        }
    }
}

struct AppDestinationView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .home:
            Text("Home Root")
        case .auth:
            Text("Auth Root")
        }
    }
}

struct CoordinatorRootView: View {
    @EnvironmentRouter(AppRoute.self) private var router

    var body: some View {
        VStack(spacing: 12) {
            Button("Go Auth") { router.go(.auth) }
            Button("Go Home") { router.go(.home) }
            Button("Go Home (Many)") {
                router.goMany([.home])
            }
        }
        .padding()
    }
}
