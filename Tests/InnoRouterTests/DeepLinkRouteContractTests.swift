import Foundation
import Testing

import InnoRouterCore
import InnoRouterDeepLink

@Suite("DeepLinkRoute contract")
struct DeepLinkRouteContractTests {
    private enum ResolvableRoute: DeepLinkRoute {
        case product(id: String)

        static func resolveDeepLink(_ url: URL) -> Self? {
            guard url.scheme?.lowercased() == "innorouter",
                  url.host?.lowercased() == "app.example.com"
            else {
                return nil
            }

            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 2, components[0] == "products" else {
                return nil
            }
            return .product(id: components[1])
        }
    }

    private enum PlainRoute: Route {
        case home
    }

    @Test("A conforming route resolves one typed destination and fails closed")
    func resolvesTypedRoute() throws {
        let matched = try #require(
            URL(string: "innorouter://app.example.com/products/42")
        )
        let rejected = try #require(
            URL(string: "https://app.example.com/products/42")
        )

        #expect(ResolvableRoute.resolveDeepLink(matched) == .product(id: "42"))
        #expect(ResolvableRoute.resolveDeepLink(rejected) == nil)
    }

    @Test("The protocol supports type-erased capability discovery")
    func supportsTypeErasedDiscovery() throws {
        let url = try #require(
            URL(string: "innorouter://app.example.com/products/42")
        )

        #expect(resolve(ResolvableRoute.self, url: url) == .product(id: "42"))
        #expect(resolve(PlainRoute.self, url: url) == nil)
    }

    private func resolve<R: Route>(_ routeType: R.Type, url: URL) -> R? {
        guard let resolver = routeType as? any DeepLinkRoute.Type else {
            return nil
        }
        return resolver.resolveDeepLink(url) as? R
    }
}

@Suite("DeepLink package grammar parity")
struct DeepLinkPackageGrammarParityTests {
    private enum GrammarRoute: Route {
        case matched
    }

    @Test("The package grammar and public matcher emit identical diagnostics")
    func packageGrammarMatchesRuntimeMatcher() {
        let patterns = [
            "/api/*/users",
            "/home",
            "/home",
            "/files/*",
            "/files/public",
            "/:slug",
            "/settings",
        ]
        let packageDiagnostics = DeepLinkPattern.makeDiagnostics(
            for: patterns.map(DeepLinkPattern.init)
        )
        let mappings = patterns.map { pattern in
            DeepLinkMapping<GrammarRoute>(pattern) { _ in .matched }
        }
        let matcher = DeepLinkMatcher<GrammarRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            mappings
        }

        #expect(packageDiagnostics == matcher.diagnostics)
    }
}
