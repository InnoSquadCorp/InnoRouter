import SwiftUI

import InnoRouter

@Router
enum HomeRoute {
    case detail(id: String)
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

struct StandaloneExampleView: View {
    var body: some View {
        RouterHost(HomeRoute.self) {
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
