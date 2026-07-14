import SwiftUI

import InnoRouter

@Routable
enum ProductRoute {
    case list
    case detail(id: String)
    case login
}

struct DeepLinkExampleView: View {
    @State private var store = NavigationStore<ProductRoute>()
    @State private var isAuthenticated = false

    private func makePipeline(isAuthenticated: Bool) -> DeepLinkPipeline<ProductRoute> {
        let matcher = DeepLinkMatcher<ProductRoute> {
            DeepLinkMapping("/products") { _ in .list }
            DeepLinkMapping("/products/:id") { params in
                params.firstValue(forName: "id").map { .detail(id: $0) }
            }
        }

        return DeepLinkPipeline(
            allowedSchemes: ["myapp", "https"],
            allowedHosts: ["myapp.com"],
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .detail = route { return true }
                    return false
                },
                isAuthenticated: { isAuthenticated }
            ),
            plan: { route in NavigationPlan(commands: [.push(route)]) }
        )
    }

    var body: some View {
        let pipeline = makePipeline(isAuthenticated: isAuthenticated)

        NavigationHost(store: store) { route in
            switch route {
            case .list:
                VStack {
                    Text("Products")
                    Button("Simulate deep link /products/123") {
                        handle(
                            url: URL(string: "myapp://myapp.com/products/123")!,
                            pipeline: pipeline
                        )
                    }
                    Button(isAuthenticated ? "Logout" : "Login") {
                        isAuthenticated.toggle()
                    }
                }
            case .detail(let id):
                Text("Detail \(id)")
            case .login:
                Text("Login")
            }
        } root: {
            Text("Root")
                .onAppear { _ = store.execute(.replace([.list])) }
        }
    }

    private func handle(url: URL, pipeline: DeepLinkPipeline<ProductRoute>) {
        switch pipeline.decide(for: url) {
        case .plan(let plan):
            for command in plan.commands {
                _ = store.execute(command)
            }
        case .pending:
            _ = store.execute(.push(.login))
        case .rejected(_), .unhandled(_):
            break
        }
    }
}
