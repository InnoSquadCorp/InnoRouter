#if canImport(InnoRouterMacrosPlugin)
import Foundation
import SwiftUI
import Testing

import InnoRouterCore
import InnoRouterDeepLink
import InnoRouterMacros

@Router(
    deepLinkSchemes: ["https"],
    deepLinkHosts: ["strasse.example", "bank.example"],
    inspectorCatalog: true
)
private enum OriginExactnessRoute {
    @DeepLink("/pay/:id")
    case pay(id: String)

    @DeepLink("/search")
    case search(q: String?)

    var destination: some View { EmptyView() }
}

// Declared in uppercase: the macro folds ASCII letters only.
@Router(deepLinkSchemes: ["HTTPS"], deepLinkHosts: ["Bank.Example"])
private enum UppercaseOriginRoute {
    @DeepLink("/pay/:id")
    case pay(id: String)

    var destination: some View { EmptyView() }
}

/// Generated resolvers must stay fail closed for origins and malformed input.
@Suite("Generated deep-link origin exactness")
struct RouterDeepLinkOriginExactnessBehaviorTests {
    private func resolve(_ string: String) throws -> OriginExactnessRoute? {
        OriginExactnessRoute.resolveDeepLink(try #require(URL(string: string)))
    }

    @Test("An uppercase ASCII declaration matches its lowercase origin, and nothing else")
    func uppercaseDeclarationFoldsASCIIOnly() throws {
        let lowercase = try #require(URL(string: "https://bank.example/pay/1"))
        let uppercase = try #require(URL(string: "HTTPS://BANK.EXAMPLE/pay/1"))
        let kelvin = try #require(URL(string: "https://ban%E2%84%AA.example/pay/1"))
        #expect(UppercaseOriginRoute.resolveDeepLink(lowercase) == .pay(id: "1"))
        #expect(UppercaseOriginRoute.resolveDeepLink(uppercase) == .pay(id: "1"))
        // A percent-encoded Kelvin sign is decoded without IDNA mapping, so
        // it stays the Kelvin sign, which is not the letter k.
        #expect(UppercaseOriginRoute.resolveDeepLink(kelvin) == nil)
    }

    @Test("Exact and ASCII-case-varied origins resolve")
    func asciiCaseVariantsResolve() throws {
        #expect(try resolve("https://strasse.example/pay/1") == .pay(id: "1"))
        #expect(try resolve("HTTPS://STRASSE.Example/pay/1") == .pay(id: "1"))
        #expect(try resolve("https://bank.example/search?q=a%20b") == .search(q: "a b"))
        #expect(try resolve("https://bank.example/search") == .search(q: nil))
    }

    @Test("A host that matches only after Unicode folding is rejected")
    func unicodeFoldedHostsAreRejected() throws {
        // ß compares equal to "ss" under Foundation's case-insensitive compare.
        #expect(try resolve("https://stra%C3%9Fe.example/pay/1") == nil)
        // The Kelvin sign lowercases to ASCII "k".
        #expect(try resolve("https://ban%E2%84%AA.example/pay/1") == nil)
    }

    @Test("A raw non-ASCII host is compared as Foundation's URL reports it")
    func rawHostIsComparedAfterIDNAMapping() throws {
        // Written raw, the host is mapped through IDNA before any comparison,
        // as name resolution maps it: this URL names the host bank.example.
        let raw = try #require(URL(string: "https://ban\u{212A}.example/pay/1"))
        #expect(raw.host == "bank.example", "Foundation no longer maps a raw host through IDNA")
        #expect(OriginExactnessRoute.resolveDeepLink(raw) == .pay(id: "1"))
        // Percent-encoded, it is only decoded, and stays the Kelvin sign.
        let encoded = try #require(URL(string: "https://ban%E2%84%AA.example/pay/1"))
        #expect(encoded.host == "ban\u{212A}.example")
        #expect(OriginExactnessRoute.resolveDeepLink(encoded) == nil)
    }

    @Test("Credentials and ports are rejected")
    func credentialsAndPortsAreRejected() throws {
        #expect(try resolve("https://user@bank.example/pay/1") == nil)
        #expect(try resolve("https://bank.example:8443/pay/1") == nil)
    }

    @Test("Undecodable userinfo is rejected as credentials")
    func undecodableUserinfoIsRejected() throws {
        #expect(try resolve("https://%FF@bank.example/pay/1") == nil)
        #expect(try resolve("https://x:%FF@bank.example/pay/1") == nil)
    }

    @Test("Undecodable percent-encoding is never delivered to a route")
    func malformedPercentEncodingIsNeverDelivered() throws {
        // A required value is always a path placeholder, and fails the route.
        #expect(try resolve("https://strasse.example/pay/%FF") == nil)
        // A query value is always optional, but one that does not decode is
        // invalid input, not a missing value or an empty string.
        #expect(try resolve("https://bank.example/search?q=%FF") == nil)
        #expect(try resolve("https://bank.example/search?q=%FF&q=ok") == nil)
        #expect(try resolve("https://bank.example/search?q=") == .search(q: ""))
        // A query item the route does not read does not decide the match.
        #expect(try resolve("https://bank.example/pay/1?utm_campaign=caf%E9") == .pay(id: "1"))
    }

    @Test("Explanations agree with the resolver")
    func explanationsAgree() throws {
        let folded = try #require(URL(string: "https://stra%C3%9Fe.example/pay/1"))
        #expect(
            OriginExactnessRoute.explainDeepLink(folded).decision
                == .rejected(.hostNotAllowed(actual: folded.host))
        )
        // A malformed URL is no pattern's candidate, so the explanation never
        // reaches the resolver and can never report an accepted route.
        let malformed = try #require(URL(string: "https://strasse.example/pay/%FF"))
        let explanation = OriginExactnessRoute.explainDeepLink(malformed)
        guard case .rejected = explanation.decision else {
            Issue.record("A malformed URL was explained as accepted: \(explanation.decision)")
            return
        }
        #expect(explanation.attempts.allSatisfy { $0.outcome == .pathMismatch })
    }
}
#endif
