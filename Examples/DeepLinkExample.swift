import SwiftUI

import InnoRouter

@Router(
    deepLinkSchemes: ["myapp", "https"],
    deepLinkHosts: ["myapp.com"]
)
enum ProductRoute {
    @DeepLink("/products/:id")
    case detail(id: String)

    var destination: some View {
        switch self {
        case .detail(let id):
            Text("Product \(id)")
        }
    }
}

struct DeepLinkExampleView: View {
    var body: some View {
        // RouterHost resolves matching onOpenURL values and pushes the route.
        RouterHost(ProductRoute.self) {
            ProductListView()
        }
    }
}

private struct ProductListView: View {
    @EnvironmentRouter(ProductRoute.self) private var router

    var body: some View {
        List {
            Button("Open product 123") {
                router.go(.detail(id: "123"))
            }

            Text("Deep link: myapp://myapp.com/products/123")
        }
        .navigationTitle("Products")
    }
}

// Use DeepLinkPipeline when authentication, pending/resume, or multi-step
// navigation needs explicit application policy.
