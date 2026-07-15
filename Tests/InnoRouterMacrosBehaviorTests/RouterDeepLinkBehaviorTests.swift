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

    static func parseDeepLinkParameter(_ value: String) -> Self? {
        value.isEmpty ? nil : Self(rawValue: value)
    }
}

@Router(
    deepLinkSchemes: ["innorouter", "https"],
    deepLinkHosts: ["app.example.com"]
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
    deepLinkHosts: ["app.example.com"]
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

@Suite("@Router deep-link behavior")
struct RouterDeepLinkBehaviorTests {
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
}

#endif
