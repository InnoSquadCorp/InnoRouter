// MARK: - Platform: NavigationSplitView is unavailable on watchOS, so the
// `CoordinatorSplitHost`-based example is compiled only on non-watchOS
// platforms. watchOS apps should use `CoordinatorHost` instead.
#if !os(watchOS)
import SwiftUI

import InnoRouter

@Routable
enum SplitRoute {
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
    @EnvironmentNavigationIntent(SplitRoute.self) private var navigationIntent

    var body: some View {
        List {
            Button("Dashboard") { navigationIntent(.go(.dashboard)) }
            Button("Reports") { navigationIntent(.go(.reports)) }
            Button("Settings") { navigationIntent(.go(.settings)) }
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
