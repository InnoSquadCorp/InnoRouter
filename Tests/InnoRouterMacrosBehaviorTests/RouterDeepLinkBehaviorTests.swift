// MARK: - RouterDeepLinkBehaviorTests.swift
// InnoRouter macro behavior tests - @Router + @DeepLink
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import Foundation
import SwiftUI
import Testing

import InnoRouterMacros

private struct BehaviorProductID: Hashable, Sendable, DeepLinkParameterValue {
    let rawValue: String

    var deepLinkParameterString: String { rawValue }

    static func parseDeepLinkParameter(_ value: String) -> Self? {
        value.isEmpty ? nil : Self(rawValue: value)
    }
}

private struct BehaviorShadowedUUID: Hashable, Sendable, DeepLinkParameterValue {
    nonisolated(unsafe) private static var parseCount = 0
    let rawValue: String

    var deepLinkParameterString: String { rawValue }

    static func parseDeepLinkParameter(_ value: String) -> Self? {
        parseCount += 1
        return Self(rawValue: value)
    }

    static func resetParseCount() { parseCount = 0 }
    static var observedParseCount: Int { parseCount }
}

private struct BehaviorShadowedString: Hashable, Sendable, DeepLinkParameterValue {
    nonisolated(unsafe) private static var parseCount = 0
    let rawValue: String

    var deepLinkParameterString: String { rawValue }

    static func parseDeepLinkParameter(_ value: String) -> Self? {
        parseCount += 1
        return Self(rawValue: value)
    }

    static func resetParseCount() { parseCount = 0 }
    static var observedParseCount: Int { parseCount }
}

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"],
    inspectorCatalog: true
)
private enum BehaviorDeepLinkRoute {
    @DeepLink("/products/:id")
    case product(id: String)

    @DeepLink("/search")
    case search(page: Int?)

    @DeepLink("/custom/:id")
    case custom(id: BehaviorProductID)

    @DeepLink("/flags/:enabled")
    case flag(enabled: Bool)

    static func resolveDeepLink(_ value: String) -> Self? {
        value == "overload" ? .product(id: value) : nil
    }

    var destination: some View {
        EmptyView()
    }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["app.example.com"],
    inspectorCatalog: true
)
private enum SpecificityBehaviorDeepLinkRoute {
    @DeepLink("/*")
    case fallback

    @DeepLink("/:id")
    case identifier(id: UUID)

    @DeepLink("/settings")
    case settings

    var destination: some View {
        EmptyView()
    }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["roundtrip.example.com"]
)
private enum RoundTripBehaviorDeepLinkRoute {
    @DeepLink("/:value")
    case value(value: String)

    @DeepLink("/settings")
    case settings

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["app.example.com"]
)
private enum GenericBehaviorDeepLinkRoute<Value>
where Value: Hashable & Sendable & DeepLinkParameterValue {
    @DeepLink("/values/:value")
    case value(value: Value)

    var destination: some View {
        EmptyView()
    }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["shadow.example.com"],
    inspectorCatalog: true
)
private enum ShadowedAliasDeepLinkRoute {
    typealias UUID = BehaviorShadowedUUID

    @DeepLink("/items/:id")
    case item(id: UUID)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["shadow-string.example.com"],
    inspectorCatalog: true
)
private enum ShadowedStringAliasDeepLinkRoute {
    typealias String = BehaviorShadowedString

    @DeepLink("/items/:id")
    case item(id: String)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["feature.example.com"],
    inspectorCatalog: true
)
private enum FeatureChildDeepLinkRoute {
    @DeepLink("/profile/:id")
    case profile(id: String)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["feature.example.com"],
    inspectorCatalog: true
)
private enum FeatureParentDeepLinkRoute {
    @FeatureRoute("account")
    case account(FeatureChildDeepLinkRoute)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["feature.example.com"],
    inspectorCatalog: true
)
private enum AmbiguousFeatureParentDeepLinkRoute {
    @FeatureRoute("primary")
    case primary(FeatureChildDeepLinkRoute)
    @FeatureRoute("secondary")
    case secondary(FeatureChildDeepLinkRoute)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["innorouter"],
    deepLinkHosts: ["child.example.com"],
    inspectorCatalog: true
)
private enum DistinctOriginChildRoute {
    @DeepLink("/child/:id")
    case child(id: String)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["https"],
    deepLinkHosts: ["parent.example.com"],
    inspectorCatalog: true
)
private enum DistinctOriginParentRoute {
    @DeepLink("/parent")
    case parent

    @FeatureRoute("child")
    case child(DistinctOriginChildRoute)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["middle"],
    deepLinkHosts: ["middle.example.com"],
    inspectorCatalog: true
)
private enum NestedOriginMiddleRoute {
    @FeatureRoute("leaf")
    case leaf(DistinctOriginChildRoute)

    var destination: some View { EmptyView() }
}

@Router(
    deepLinkSchemes: ["outer"],
    deepLinkHosts: ["outer.example.com"],
    inspectorCatalog: true
)
private enum NestedOriginOuterRoute {
    @FeatureRoute("middle")
    case middle(NestedOriginMiddleRoute)

    var destination: some View { EmptyView() }
}

@Suite("@Router deep-link behavior")
struct RouterDeepLinkBehaviorTests {
    @Test("Generated URLs are returned only when they resolve to the same route")
    func generatedURLMustRoundTripToTheSameRoute() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "roundtrip.example.com")
        )

        #expect(RoundTripBehaviorDeepLinkRoute.value(value: "settings").deepLinkURL(
            origin: origin
        ) == nil)
        let settingsURL = try #require(
            RoundTripBehaviorDeepLinkRoute.settings.deepLinkURL(origin: origin)
        )
        #expect(RoundTripBehaviorDeepLinkRoute.resolveDeepLink(settingsURL) == .settings)
    }

    @Test("Empty required path values and ambiguous feature URLs fail closed")
    func generatedURLRejectsNonRoundTrippableRoutes() throws {
        let appOrigin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "app.example.com")
        )
        let featureOrigin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "feature.example.com")
        )

        #expect(BehaviorDeepLinkRoute.product(id: "").deepLinkURL(origin: appOrigin) == nil)
        #expect(
            AmbiguousFeatureParentDeepLinkRoute.primary(.profile(id: "42"))
                .deepLinkURL(origin: featureOrigin) == nil
        )
    }

    @Test("Feature URL rendering delegates origin admission to the owning route")
    func featureURLRenderingUsesChildOrigin() throws {
        let parentOrigin = try #require(
            DeepLinkOrigin(scheme: "https", host: "parent.example.com")
        )
        let childOrigin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "child.example.com")
        )

        #expect(
            DistinctOriginParentRoute.child(.child(id: "42"))
                .deepLinkURL(origin: childOrigin)?.absoluteString ==
                "innorouter://child.example.com/child/42"
        )
        #expect(DistinctOriginParentRoute.parent.deepLinkURL(origin: childOrigin) == nil)
        #expect(
            DistinctOriginParentRoute.parent.deepLinkURL(origin: parentOrigin)?.absoluteString ==
                "https://parent.example.com/parent"
        )

        let nested = NestedOriginOuterRoute.middle(.leaf(.child(id: "nested")))
        let nestedURL = try #require(nested.deepLinkURL(origin: childOrigin))
        #expect(nestedURL.absoluteString == "innorouter://child.example.com/child/nested")
        #expect(NestedOriginOuterRoute.resolveDeepLink(nestedURL) == nested)
        #expect(
            NestedOriginOuterRoute.deepLinkCatalog.entries[0].featurePath == ["middle", "leaf"]
        )
    }

    @Test("Shadowed framework names remain application-owned during pure explanation")
    func shadowedFrameworkTypeNameDoesNotRunApplicationCode() throws {
        let url = try #require(
            URL(string: "innorouter://shadow.example.com/items/secret")
        )
        BehaviorShadowedUUID.resetParseCount()

        #expect(
            ShadowedAliasDeepLinkRoute.deepLinkCatalog.entries[0]
                .parameters[0].isApplicationConversionRequired
        )
        #expect(ShadowedAliasDeepLinkRoute.explainDeepLink(url).decision == .rejected(
            .customResolverNotEvaluated
        ))
        #expect(BehaviorShadowedUUID.observedParseCount == 0)
    }

    @Test("A shadowed String payload compiles while catalog names remain Swift strings")
    func shadowedStringTypeNameCompilesAndRemainsApplicationOwned() throws {
        let url = try #require(
            URL(string: "innorouter://shadow-string.example.com/items/secret")
        )
        BehaviorShadowedString.resetParseCount()

        #expect(
            ShadowedStringAliasDeepLinkRoute.deepLinkCatalog.entries[0]
                .parameters[0].isApplicationConversionRequired
        )
        #expect(
            ShadowedStringAliasDeepLinkRoute.explainDeepLink(url).decision == .rejected(
                .customResolverNotEvaluated
            )
        )
        #expect(BehaviorShadowedString.observedParseCount == 0)
        #expect(
            ShadowedStringAliasDeepLinkRoute.resolveDeepLink(url) ==
                .item(id: .init(rawValue: "secret"))
        )
        #expect(BehaviorShadowedString.observedParseCount == 1)
    }

    @Test("Parent catalogs compose child feature entries and resolve the same declaration")
    func parentCatalogIncludesChildFeatureEntries() throws {
        let url = try #require(
            URL(string: "innorouter://feature.example.com/profile/42")
        )

        #expect(FeatureParentDeepLinkRoute.deepLinkCatalog.entries.count == 1)
        #expect(FeatureParentDeepLinkRoute.deepLinkCatalog.entries[0].featurePath == ["account"])
        #expect(FeatureParentDeepLinkRoute.deepLinkCatalog.entries[0].routeCase == "account.profile")
        #expect(
            FeatureParentDeepLinkRoute.resolveDeepLink(url) ==
                .account(.profile(id: "42"))
        )
        #expect(FeatureParentDeepLinkRoute.explainDeepLink(url).decision == .accepted(
            routeCase: "account.profile",
            pattern: "/profile/:id"
        ))
    }

    @Test("Ambiguous feature instances fail closed instead of using declaration order")
    func ambiguousFeatureCatalogFailsClosed() throws {
        let url = try #require(
            URL(string: "innorouter://feature.example.com/profile/42")
        )

        #expect(AmbiguousFeatureParentDeepLinkRoute.deepLinkCatalog.entries.count == 2)
        #expect(AmbiguousFeatureParentDeepLinkRoute.resolveDeepLink(url) == nil)
    }

    @Test("Macro catalog explains matching and conversion failures without payloads")
    func generatedCatalogAndExplanation() throws {
        let valid = try #require(URL(string: "https://app.example.com/products/42"))
        let invalid = try #require(URL(string: "https://app.example.com/search?page=nope"))

        #expect(BehaviorDeepLinkRoute.deepLinkCatalog.entries.map(\.routeCase) == [
            "product", "search", "custom", "flag",
        ])
        #expect(BehaviorDeepLinkRoute.deepLinkCatalog.entries.allSatisfy {
            $0.declarationNamespace == "BehaviorDeepLinkRoute"
        })
        #expect(Set(BehaviorDeepLinkRoute.deepLinkCatalog.entries.map(\.id)).count == 4)
        #expect(BehaviorDeepLinkRoute.deepLinkCatalog.entries[0].parameters == [
            .init(name: "id", typeName: "String", source: .path, isRequired: true),
        ])
        #expect(BehaviorDeepLinkRoute.explainDeepLink(valid).decision == .accepted(
            routeCase: "product",
            pattern: "/products/:id"
        ))
        #expect(BehaviorDeepLinkRoute.explainDeepLink(invalid).decision == .rejected(
            .parameterConversionFailed(candidatePatterns: ["/search"])
        ))
    }

    @Test("Generated resolver admits exact origins and builds typed payloads")
    func exactOriginAndPayload() throws {
        let url = try #require(
            URL(string: "innorouter://app.example.com/products/hello%2Fworld")
        )

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(url) == .product(id: "hello/world"))
    }

    @Test("Origin allowlists are case insensitive")
    func caseInsensitiveOrigin() throws {
        let url = try #require(
            URL(string: "HTTPS://APP.EXAMPLE.COM/products/42")
        )

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(url) == .product(id: "42"))
    }

    @Test("Generated resolver rejects suffix and subdomain host attacks")
    func rejectsHostAttacks() throws {
        let suffix = try #require(
            URL(string: "innorouter://app.example.com.evil.test/products/42")
        )
        let subdomain = try #require(
            URL(string: "innorouter://sub.app.example.com/products/42")
        )

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(suffix) == nil)
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(subdomain) == nil)
    }

    @Test(
        "Generated resolver rejects missing or disallowed origins",
        arguments: [
            "http://app.example.com/products/42",
            "https://evil.example.com/products/42",
            "//app.example.com/products/42",
            "innorouter:/products/42",
        ]
    )
    func rejectsMissingOrDisallowedOrigin(urlString: String) throws {
        let url = try #require(URL(string: urlString))

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(url) == nil)
    }

    @Test("Generated resolver rejects user-info and explicit ports")
    func rejectsNoncanonicalOrigins() throws {
        let userInfo = try #require(
            URL(string: "innorouter://user@app.example.com/products/42")
        )
        let port = try #require(
            URL(string: "https://app.example.com:443/products/42")
        )

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(userInfo) == nil)
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(port) == nil)
    }

    @Test("Optional query values distinguish missing, valid, and invalid input")
    func optionalQuery() throws {
        let missing = try #require(URL(string: "https://app.example.com/search"))
        let valid = try #require(URL(string: "https://app.example.com/search?page=3"))
        let invalid = try #require(URL(string: "https://app.example.com/search?page=nope"))

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(missing) == .search(page: nil))
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(valid) == .search(page: 3))
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(invalid) == nil)
    }

    @Test("Path captures win over query values with the same name")
    func pathPrecedesQuery() throws {
        let url = try #require(
            URL(string: "https://app.example.com/products/path?id=query")
        )

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(url) == .product(id: "path"))
    }

    @Test("Custom nominal and Bool parameter conformances are type checked")
    func customParameterTypes() throws {
        let custom = try #require(
            URL(string: "https://app.example.com/custom/sku-42")
        )
        let flag = try #require(
            URL(string: "https://app.example.com/flags/true")
        )

        #expect(
            BehaviorDeepLinkRoute.resolveDeepLink(custom) ==
                .custom(id: BehaviorProductID(rawValue: "sku-42"))
        )
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(flag) == .flag(enabled: true))
    }

    @Test("Generic routes compile without static storage")
    func genericRoute() throws {
        let url = try #require(
            URL(string: "innorouter://app.example.com/values/42")
        )

        #expect(GenericBehaviorDeepLinkRoute<Int>.resolveDeepLink(url) == .value(value: 42))
    }

    @Test("Generated mappings prefer literals, then typed parameters, then wildcards")
    func specificityOrder() throws {
        let settings = try #require(
            URL(string: "innorouter://app.example.com/settings")
        )
        let identifier = try #require(
            URL(string: "innorouter://app.example.com/550e8400-e29b-41d4-a716-446655440000")
        )
        let fallback = try #require(
            URL(string: "innorouter://app.example.com/not-a-uuid")
        )
        let expectedIdentifier = try #require(
            UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")
        )

        #expect(SpecificityBehaviorDeepLinkRoute.resolveDeepLink(settings) == .settings)
        #expect(
            SpecificityBehaviorDeepLinkRoute.resolveDeepLink(identifier) ==
                .identifier(id: expectedIdentifier)
        )
        #expect(SpecificityBehaviorDeepLinkRoute.resolveDeepLink(fallback) == .fallback)
        #expect(SpecificityBehaviorDeepLinkRoute.explainDeepLink(fallback).decision == .accepted(
            routeCase: "fallback",
            pattern: "/*"
        ))
    }

    @Test("Non-URL resolver overloads coexist with the generated witness")
    func resolverOverload() {
        #expect(BehaviorDeepLinkRoute.resolveDeepLink("overload") == .product(id: "overload"))
    }

    @Test("Default input limits fail closed")
    func inputLimit() throws {
        let oversizedPath = String(repeating: "a", count: 8_193)
        let url = try #require(
            URL(string: "https://app.example.com/products/\(oversizedPath)")
        )

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(url) == nil)
    }

    @Test("Generated URLs round-trip path and optional query payloads")
    func generatedURLRoundTrip() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "HTTPS", host: "APP.EXAMPLE.COM")
        )
        let product = BehaviorDeepLinkRoute.product(id: "hello/world")
        let search = BehaviorDeepLinkRoute.search(page: 3)

        let productURL = try #require(product.deepLinkURL(origin: origin))
        let searchURL = try #require(search.deepLinkURL(origin: origin))

        #expect(productURL.absoluteString == "https://app.example.com/products/hello%2Fworld")
        #expect(searchURL.absoluteString == "https://app.example.com/search?page=3")
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(productURL) == product)
        #expect(BehaviorDeepLinkRoute.resolveDeepLink(searchURL) == search)
    }

    @Test("Generated URLs omit nil query values and reject undeclared origins")
    func generatedURLOriginPolicy() throws {
        let allowed = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "app.example.com")
        )
        let disallowed = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "other.example.com")
        )

        #expect(
            BehaviorDeepLinkRoute.search(page: nil).deepLinkURL(origin: allowed)?.absoluteString ==
                "innorouter://app.example.com/search"
        )
        #expect(BehaviorDeepLinkRoute.search(page: nil).deepLinkURL(origin: disallowed) == nil)
    }

    @Test("Custom and generic parameter printers round-trip")
    func generatedURLTypedValues() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "app.example.com")
        )
        let custom = BehaviorDeepLinkRoute.custom(id: .init(rawValue: "sku 42"))
        let generic = GenericBehaviorDeepLinkRoute<Int>.value(value: 42)

        let customURL = try #require(custom.deepLinkURL(origin: origin))
        let genericURL = try #require(generic.deepLinkURL(origin: origin))

        #expect(BehaviorDeepLinkRoute.resolveDeepLink(customURL) == custom)
        #expect(GenericBehaviorDeepLinkRoute<Int>.resolveDeepLink(genericURL) == generic)
    }

    @Test("Wildcard routes render their canonical literal prefix")
    func generatedWildcardURL() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "innorouter", host: "app.example.com")
        )
        let route = SpecificityBehaviorDeepLinkRoute.fallback
        let url = try #require(route.deepLinkURL(origin: origin))

        #expect(url.absoluteString == "innorouter://app.example.com/")
        #expect(SpecificityBehaviorDeepLinkRoute.resolveDeepLink(url) == route)
    }
}

#endif
