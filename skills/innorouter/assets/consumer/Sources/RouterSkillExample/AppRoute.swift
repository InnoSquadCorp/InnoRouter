import SwiftUI
import InnoRouter

@Router(deepLinkSchemes: ["routerskill", "https"], deepLinkHosts: ["router.example.com"])
public enum AppRoute: Codable {
    @TabItem("Home", systemImage: "house", id: "home")
    case home

    @TabItem("Settings", systemImage: "gear", id: "settings")
    case settings

    @DeepLink("/products/:id")
    case product(id: String)

    @PresentationResult(Bool.self)
    case confirmation

    public var destination: some View {
        switch self {
        case .home: Text("Home")
        case .settings: Text("Settings")
        case .product(let id): Text("Product \(id)")
        case .confirmation: Text("Confirmation")
        }
    }
}

@MainActor
public func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}

public func removalRequest() -> RouterTransientPresentationRequest<Bool> {
    .confirmationDialog(title: "Remove item?", actions: [
        .init(id: "remove", label: "Remove", role: .destructive, value: true),
        .init(id: "keep", label: "Keep", role: .cancel, value: false),
    ])
}
