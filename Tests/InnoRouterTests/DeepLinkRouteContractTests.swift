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

    private indirect enum ManualRecursiveRoute: DeepLinkRoute {
        case leaf(id: String)
        case child(Self)

        static var deepLinkCatalog: DeepLinkRouteCatalog {
            DeepLinkFeatureRuntime.catalog(for: Self.self) {
                DeepLinkRouteCatalog(
                    schemes: ["manual"],
                    hosts: ["app"],
                    entries: [.init(routeCase: "leaf", pattern: "/leaf/:id")]
                ).merging(
                    DeepLinkFeatureRuntime.catalog(for: Self.self)
                        .namespaced(declarationNamespace: "ManualRecursiveRoute", featureID: "child")
                )
            }
        }

        static var supportsPureDeepLinkExplanation: Bool {
            DeepLinkFeatureRuntime.supportsPureExplanation(for: Self.self) {
                DeepLinkFeatureRuntime.supportsPureExplanation(for: Self.self)
            }
        }

        static func resolveDeepLink(_ url: URL) -> Self? {
            DeepLinkFeatureRuntime.resolve(Self.self, url: url) {
                let components = url.pathComponents.filter { $0 != "/" }
                guard url.scheme == "manual", url.host == "app",
                      components.count == 2, components[0] == "leaf" else {
                    return DeepLinkFeatureRuntime.resolve(Self.self, url: url).map(Self.child)
                }
                return .leaf(id: components[1])
            }
        }

        static func deepLinkCatalogCaseName(for route: Self) -> String? {
            DeepLinkFeatureRuntime.caseName(for: route) {
                switch route {
                case .leaf:
                    "leaf"
                case .child(let child):
                    DeepLinkFeatureRuntime.caseName(for: child).map { "child.\($0)" }
                }
            }
        }

        func deepLinkURL(origin: DeepLinkOrigin) -> URL? {
            DeepLinkFeatureRuntime.url(for: self, origin: origin) {
                switch self {
                case .leaf(let id):
                    URL(string: "\(origin.scheme)://\(origin.host)/leaf/\(id)")
                case .child(let child):
                    DeepLinkFeatureRuntime.url(for: child, origin: origin)
                }
            }
        }
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
        #expect(ResolvableRoute.deepLinkCatalog.entries.isEmpty)
        #expect(!ResolvableRoute.supportsPureDeepLinkExplanation)
        #expect(ResolvableRoute.deepLinkCatalogCaseName(for: .product(id: "42")) == nil)
        #expect(ResolvableRoute.product(id: "42").deepLinkCatalogCaseNameValue() == nil)
        let origin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "app.example.com")
        )
        #expect(ResolvableRoute.product(id: "42").deepLinkURL(origin: origin) == nil)
        #expect(DeepLinkFeatureRuntime.catalog(for: PlainRoute.self).entries.isEmpty)
        #expect(!DeepLinkFeatureRuntime.supportsPureExplanation(for: PlainRoute.self))
        #expect(DeepLinkFeatureRuntime.resolve(PlainRoute.self, url: matched) == nil)
        #expect(DeepLinkFeatureRuntime.caseName(for: PlainRoute.home) == nil)
        #expect(DeepLinkFeatureRuntime.url(for: PlainRoute.home, origin: origin) == nil)
    }

    @Test("The protocol supports type-erased capability discovery")
    func supportsTypeErasedDiscovery() throws {
        let url = try #require(
            URL(string: "innorouter://app.example.com/products/42")
        )

        #expect(resolve(ResolvableRoute.self, url: url) == .product(id: "42"))
        #expect(resolve(PlainRoute.self, url: url) == nil)
    }

    @Test("Incomplete catalogs fail closed and remain Codable-compatible")
    func incompleteCatalogContract() throws {
        let entry = DeepLinkRouteCatalogEntry(
            routeCase: "product",
            pattern: "/products/:id"
        )
        let incomplete = DeepLinkRouteCatalog(
            schemes: ["innorouter"],
            hosts: ["app.example.com"],
            entries: [entry],
            isComplete: false
        )
        let url = try #require(
            URL(string: "innorouter://app.example.com/products/42")
        )

        #expect(!incomplete.isComplete)
        #expect(incomplete.entries.isEmpty)
        #expect(!incomplete.supportsPureResolution(of: url))
        #expect(
            incomplete.explain(url, resolve: ResolvableRoute.resolveDeepLink).decision
                == .rejected(.traversalLimitExceeded)
        )

        let encoded = try JSONEncoder().encode(incomplete)
        #expect(
            try JSONDecoder().decode(DeepLinkRouteCatalog.self, from: encoded)
                == incomplete
        )

        let legacy = Data(
            #"{"schemes":["innorouter"],"hosts":["app.example.com"],"entries":[]}"#.utf8
        )
        let decodedLegacy = try JSONDecoder().decode(
            DeepLinkRouteCatalog.self,
            from: legacy
        )
        #expect(decodedLegacy.isComplete)
    }

    @Test("A hand-written recursive conformer uses the same bounded root contract")
    func manualRecursiveRootContract() throws {
        let url = try #require(URL(string: "manual://app/leaf/42"))
        let origin = try #require(DeepLinkOrigin(scheme: "manual", host: "app"))

        #expect(ManualRecursiveRoute.deepLinkCatalog.isComplete)
        #expect(ManualRecursiveRoute.deepLinkCatalog.entries.map(\.routeCase) == ["leaf"])
        #expect(!ManualRecursiveRoute.supportsPureDeepLinkExplanation)
        #expect(ManualRecursiveRoute.resolveDeepLink(url) == .leaf(id: "42"))
        #expect(ManualRecursiveRoute.deepLinkCatalogCaseName(for: .leaf(id: "42")) == "leaf")
        #expect(
            ManualRecursiveRoute.deepLinkCatalogCaseName(for: .child(.leaf(id: "42"))) == nil
        )
        #expect(ManualRecursiveRoute.leaf(id: "42").deepLinkURL(origin: origin) == url)
        #expect(ManualRecursiveRoute.child(.leaf(id: "42")).deepLinkURL(origin: origin) == nil)
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
        ).map(DeepLinkMatcherDiagnostic.init)
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

    @Test("Specificity ordering removes structural shadows without reordering peers")
    func specificityOrdering() {
        let patterns = [
            "/*",
            "/:id",
            "/settings",
            "/products/:id",
            "/products/featured",
        ].map(DeepLinkPattern.init)

        let indices = DeepLinkPattern.specificityOrderedIndices(for: patterns)
        let ordered = indices.map { patterns[$0] }

        #expect(indices == [2, 1, 4, 3, 0])
        #expect(DeepLinkPattern.makeDiagnostics(for: ordered).isEmpty)
    }
}
