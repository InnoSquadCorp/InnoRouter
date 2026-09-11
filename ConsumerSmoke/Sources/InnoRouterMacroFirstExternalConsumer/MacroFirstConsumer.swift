import Foundation
import SwiftUI

import InnoRouter

public struct ExternalShadowedID: Hashable, Sendable, Codable, DeepLinkParameterValue {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var deepLinkParameterString: String { rawValue }

    public static func parseDeepLinkParameter(_ value: String) -> Self? {
        Self(rawValue: value)
    }
}

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"],
    inspectorCatalog: true
)
public enum ExternalRoute: Codable {
    public typealias UUID = ExternalShadowedID

    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    case settings

    @DeepLink("/details/:id")
    case detail(id: String)

    @DeepLink("/shadow/:id")
    case shadowed(id: UUID)

    @available(macOS 26, *)
    @PresentationResult(Bool.self)
    case futureConfirmation

    @PresentationResult(Bool.self)
#if os(macOS)
    @available(macOS 26, *)
#endif
    case conditionalFutureConfirmation

    var destination: some View {
        switch self {
        case .home:
            Text("Home")
        case .settings:
            Text("Settings")
        case .detail(let id):
            Text("Detail \(id)")
        case .shadowed(let id):
            Text("Shadowed \(id.rawValue)")
        case .futureConfirmation:
            Text("Future confirmation")
        case .conditionalFutureConfirmation:
            Text("Conditional future confirmation")
        }
    }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["shadow-string.example.com"],
    inspectorCatalog: true
)
public enum ExternalStringShadowRoute {
    public typealias String = ExternalShadowedID

    @DeepLink("/items/:id")
    case item(id: String)

    var destination: some View {
        switch self {
        case .item(let id):
            Text("Shadowed string \(id.rawValue)")
        }
    }
}

private struct ExternalActions: View {
    @EnvironmentRouter(ExternalRoute.self) private var router

    var body: some View {
        Button("Route") {
            router.go(.detail(id: "42"))
            router.sheet(.settings)
            router.dismiss()
            router.back()
        }
    }
}

@MainActor
private final class ExternalSession {
    var isAuthenticated = false
}

@MainActor
public enum MacroFirstConsumerProbe {
    public static func exercise() async throws {
        _ = RouterHost(ExternalRoute.self) {
            ExternalActions()
        }.body

#if !os(watchOS)
        _ = RouterSplitHost(ExternalRoute.self) {
            Text("Sidebar")
        } root: {
            ExternalActions()
        }.body
#endif

        _ = RouterTabHost(ExternalRoute.self, initial: .home).body

        let store = ExternalRoute.makeRouterStore()
        _ = await store.perform(.push(.detail(id: "42")))
        _ = await store.perform(.present(.init(route: .settings, style: .sheet)))
        _ = await store.perform(.dismissPresentation)

        if #available(macOS 26, *) {
            _ = ExternalRoute.Presentation.futureConfirmation
            _ = ExternalRoute.Presentation.conditionalFutureConfirmation
        }

        let codec = try RouterSnapshotCodec<ExternalRoute>(currentVersion: 1)
        let data = try await store.snapshot(using: codec)
        _ = try await store.restore(from: data, using: codec)

        if let url = URL(string: "innorouter://app.example.com/details/42") {
            let _: ExternalRoute? = ExternalRoute.resolveDeepLink(url)

            let session = ExternalSession()
            let authenticatedPipeline = RouterLinkPipeline<ExternalRoute>(
                originPolicy: .allowlisted(
                    schemes: ["innorouter"],
                    hosts: ["app.example.com"]
                ),
                customResolver: { _ in
                    RouterPlan(state: .rootStack(path: [.detail(id: "42")]))
                },
                authenticationPolicy: .required(
                    shouldRequireAuthentication: { route in
                        if case .detail = route { return true }
                        return false
                    },
                    isAuthenticated: { await session.isAuthenticated }
                )
            )
            _ = await authenticatedPipeline.decide(for: url)
        }
    }
}
