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
        RouterHost(ProductRoute.self) {
            ProductListView()
        }
    }
}

private struct ProductListView: View {
    @EnvironmentRouter(ProductRoute.self) private var router

    var body: some View {
        Button("Open product 123") {
            router.go(.detail(id: "123"))
        }
    }
}
