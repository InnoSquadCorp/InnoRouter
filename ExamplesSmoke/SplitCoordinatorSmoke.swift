// MARK: - Platform: NavigationSplitView is unavailable on watchOS, so this
// smoke target is compiled only on non-watchOS platforms.
#if !os(watchOS)
import SwiftUI

import InnoRouter

enum SplitRoute: Route {
    case dashboard
    case reports
    case settings
}

@Observable
@MainActor
final class SplitAppCoordinator: Coordinator {
    typealias RouteType = SplitRoute
    typealias Destination = SplitDestinationView

    let store = NavigationStore<SplitRoute>()

    @ViewBuilder
    func destination(for route: SplitRoute) -> SplitDestinationView {
        SplitDestinationView(route: route)
    }
}

struct SplitCoordinatorExampleView: View {
    @State private var coordinator = SplitAppCoordinator()

    var body: some View {
        CoordinatorSplitHost(coordinator: coordinator) {
            SplitSidebarView()
        } root: {
            Text("Select a destination")
                .navigationTitle("Detail")
        }
    }
}

struct SplitSidebarView: View {
    @EnvironmentRouter(SplitRoute.self) private var router

    var body: some View {
        List {
            Button("Dashboard") { router.go(.dashboard) }
            Button("Reports") { router.go(.reports) }
            Button("Settings") { router.go(.settings) }
        }
        .navigationTitle("Sidebar")
    }
}

struct SplitDestinationView: View {
    let route: SplitRoute

    var body: some View {
        switch route {
        case .dashboard:
            Text("Dashboard")
        case .reports:
            Text("Reports")
        case .settings:
            Text("Settings")
        }
    }
}

#endif
