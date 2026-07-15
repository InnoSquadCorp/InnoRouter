import SwiftUI

import InnoRouter

enum HomeRoute: Route {
    case list
    case detail(id: String)
    case settings
}

struct StandaloneExampleView: View {
    @State private var store = NavigationStore<HomeRoute>()

    var body: some View {
        NavigationHost(store: store) { route in
            switch route {
            case .list:
                HomeListView()
            case .detail(let id):
                Text("Detail \(id)")
            case .settings:
                Text("Settings")
            }
        } root: {
            HomeListView()
        }
    }
}

struct HomeListView: View {
    @EnvironmentRouter(HomeRoute.self) private var router

    var body: some View {
        List {
            Button("Go Detail") {
                router.go(.detail(id: "123"))
            }
            Button("Go Settings") {
                router.go(.settings)
            }
        }
        .navigationTitle("Home")
    }
}
