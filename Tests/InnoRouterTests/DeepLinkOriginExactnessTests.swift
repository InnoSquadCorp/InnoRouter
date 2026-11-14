import Foundation
import Testing

import InnoRouterCore
import InnoRouterDeepLink

/// Origin admission folds ASCII case only. Unicode case mapping would admit a
/// percent-encoded host such as `ban%E2%84%AA.example` (Kelvin sign) for the
/// allow-list entry `bank.example`, and compatibility folding would admit
/// `stra%C3%9Fe.example` for `strasse.example`.
@Suite("Deep-link origin exactness")
struct DeepLinkOriginExactnessTests {
    private enum RouteFixture: Route, Codable {
        case home
    }

    private static let kelvinHost = "https://ban%E2%84%AA.example/home"
    private static let sharpSHost = "https://stra%C3%9Fe.example/home"

    private func pipeline(hosts: Set<String>) -> RouterLinkPipeline<RouteFixture> {
        RouterLinkPipeline<RouteFixture>(
            originPolicy: .allowlisted(schemes: ["https"], hosts: hosts),
            customResolver: { _ in RouterPlan(state: .rootStack) }
        )
    }

    @Test("Pipelines admit ASCII case variants of an allowed origin")
    func pipelineAdmitsASCIICase() async throws {
        let url = try #require(URL(string: "HTTPS://BANK.Example/home"))
        guard case .plan = await pipeline(hosts: ["bank.example"]).decide(for: url) else {
            Issue.record("An ASCII case variant of an allowed origin was not admitted")
            return
        }
    }

    @Test("Pipelines reject a host that only matches after Unicode case mapping")
    func pipelineRejectsUnicodeLowercasedHost() async throws {
        let url = try #require(URL(string: Self.kelvinHost))
        #expect(
            await pipeline(hosts: ["bank.example"]).decide(for: url)
                == .rejected(reason: .hostNotAllowed(actualHost: url.host))
        )
    }

    @Test("Pipelines reject a host that only matches after compatibility folding")
    func pipelineRejectsFoldedHost() async throws {
        let url = try #require(URL(string: Self.sharpSHost))
        #expect(
            await pipeline(hosts: ["strasse.example"]).decide(for: url)
                == .rejected(reason: .hostNotAllowed(actualHost: url.host))
        )
    }

    @Test("Catalog explanations reject Unicode-folded hosts and keep ASCII case variants")
    func catalogExplanation() throws {
        let catalog = DeepLinkRouteCatalog(
            schemes: ["https"],
            hosts: ["bank.example", "strasse.example"],
            entries: [.init(routeCase: "home", pattern: "/home")]
        )
        let resolve: (URL) -> RouteFixture? = { _ in .home }

        for rejected in [Self.kelvinHost, Self.sharpSHost] {
            let url = try #require(URL(string: rejected))
            #expect(
                catalog.explain(url, resolve: resolve).decision
                    == .rejected(.hostNotAllowed(actual: url.host))
            )
            #expect(!catalog.supportsPureResolution(of: url))
        }

        let upper = try #require(URL(string: "HTTPS://BANK.EXAMPLE/home"))
        #expect(
            catalog.explain(upper, resolve: resolve).decision
                == .accepted(routeCase: "home", pattern: "/home")
        )
        #expect(catalog.supportsPureResolution(of: upper))
    }

    @Test("Generated-resolver origin admission is exact apart from ASCII case")
    func generatedAdmission() throws {
        func admits(_ string: String) throws -> Bool {
            DeepLinkFeatureRuntime.admitsOrigin(
                of: try #require(URL(string: string)),
                schemes: ["https"],
                hosts: ["bank.example", "strasse.example"]
            )
        }

        #expect(try admits("https://bank.example/home"))
        #expect(try admits("HTTPS://Bank.EXAMPLE/home"))
        #expect(try !admits(Self.kelvinHost))
        #expect(try !admits(Self.sharpSHost))
        #expect(try !admits("https://user@bank.example/home"))
        #expect(try !admits("https://bank.example:8443/home"))
        #expect(try !admits("http://bank.example/home"))
        #expect(try !admits("https://bank.example.evil.test/home"))
    }

    @Test("A typed origin never becomes ASCII through Unicode lowercasing")
    func typedOriginRejectsNonASCII() {
        #expect(DeepLinkOrigin(scheme: "https", host: "ban\u{212A}.example") == nil)
        #expect(DeepLinkOrigin(scheme: "https", host: "BANK.example")?.host == "bank.example")
    }

    @Test("Undecodable userinfo counts as credentials on every admission path")
    func undecodableUserinfoIsRejected() async throws {
        // `URL.user` is nil for these, so a nil check alone would admit them.
        for string in ["https://%FF@bank.example/home", "https://x:%FF@bank.example/home",
                       "https://bank.example%C0%AF@bank.example/home", "https://@bank.example/home"] {
            let url = try #require(URL(string: string))
            #expect(!DeepLinkFeatureRuntime.admitsOrigin(of: url, schemes: ["https"], hosts: ["bank.example"]))
            #expect(
                await pipeline(hosts: ["bank.example"]).decide(for: url)
                    == .rejected(reason: .hostNotAllowed(actualHost: url.host)),
                "\(string) was admitted by the pipeline"
            )
            let catalog = DeepLinkRouteCatalog(
                schemes: ["https"], hosts: ["bank.example"],
                entries: [.init(routeCase: "home", pattern: "/home")]
            )
            #expect(!catalog.supportsPureResolution(of: url))
            let resolve: (URL) -> RouteFixture? = { _ in .home }
            #expect(catalog.explain(url, resolve: resolve).decision == .rejected(.credentialsNotAllowed))
        }
    }

    @Test("Every admission path compares bytes, not canonically equivalent strings")
    func canonicalEquivalenceIsNotEquality() async throws {
        // The allow-list entry is precomposed (U+00E9); the URL host decodes
        // to the decomposed spelling (e + U+0301). Swift `String ==` calls
        // these equal.
        let allowed = "caf\u{E9}.example"
        let url = try #require(URL(string: "https://cafe%CC%81.example/home"))
        #expect(url.host == allowed, "The fixture no longer exercises canonical equivalence")
        #expect(!DeepLinkFeatureRuntime.admitsOrigin(of: url, schemes: ["https"], hosts: [allowed]))
        #expect(
            await pipeline(hosts: [allowed]).decide(for: url)
                == .rejected(reason: .hostNotAllowed(actualHost: url.host))
        )
    }

    @Test("Allow-list spellings that fold to canonically equivalent strings are all kept")
    func foldedSpellingsStayDistinct() async throws {
        // Not equivalent as written (é against É), but after ASCII folding
        // `CAFE\u{301}` becomes the decomposed spelling of `caf\u{E9}`.
        let precomposed = try #require(URL(string: "https://caf%C3%A9.example/home"))
        let decomposed = try #require(URL(string: "https://cafe%CC%81.example/home"))
        let hosts: Set<String> = ["caf\u{E9}.example", "CAFE\u{301}.example"]
        #expect(hosts.count == 2)
        for url in [precomposed, decomposed] {
            guard case .plan = await pipeline(hosts: hosts).decide(for: url) else {
                Issue.record("An explicitly allowed spelling was rejected: \(url.absoluteString)")
                continue
            }
        }

        // Catalog merging keeps both spellings for the same reason.
        let first = DeepLinkRouteCatalog(
            schemes: ["https"], hosts: ["caf\u{E9}.example"],
            entries: [.init(routeCase: "home", pattern: "/home")]
        )
        let second = DeepLinkRouteCatalog(
            schemes: ["HTTPS"], hosts: ["cafe\u{301}.example"],
            entries: [.init(routeCase: "other", pattern: "/other")]
        )
        let merged = first.merging(second)
        #expect(merged.schemes == ["https"])
        #expect(merged.hosts.count == 2)
        #expect(merged.supportsPureResolution(of: precomposed))
        #expect(merged.supportsPureResolution(of: decomposed))
    }

    @Test("Undecodable percent-encoding is never compared, and no typed read accepts it")
    func malformedPercentEncoding() throws {
        let matcher = DeepLinkMatcher<String> {
            DeepLinkMapping("/pay/:id") { parameters in
                parameters.firstValue(forName: "id")
            }
            DeepLinkMapping("/search") { parameters in
                // Mirrors a generated optional binding: present, then typed.
                guard parameters.firstValue(forName: "q") != nil else { return "<none>" }
                return parameters.firstValue(forName: "q", as: String.self)
            }
            DeepLinkMapping("/page") { parameters in
                guard parameters.firstValue(forName: "n") != nil else { return "<none>" }
                return parameters.firstValue(forName: "n", as: Int.self).map(String.init)
            }
            DeepLinkMapping("/all") { parameters in
                parameters.values(forName: "n", as: Int.self).map(String.init).joined(separator: ",")
            }
            DeepLinkMapping("/raw") { parameters in
                parameters.firstValue(forName: "q").map { "raw:\($0)" }
            }
            DeepLinkMapping("/files/*") { _ in "files" }
        }

        // Controls: valid encodings still decode exactly once.
        #expect(matcher.match("https://bank.example/pay/a%2Fb") == "a/b")
        #expect(matcher.match("https://bank.example/pay/%ED%95%9C") == "한")
        #expect(matcher.match("https://bank.example/pay/100%25") == "100%")
        #expect(matcher.match("https://bank.example/pay/%25FF") == "%FF")
        #expect(matcher.match("https://bank.example/search?q=a%20b") == "a b")
        #expect(matcher.match("https://bank.example/search") == "<none>")
        #expect(matcher.match("https://bank.example/search?q=") == "")

        // `%FF` is not UTF-8. A parameter position never receives it, and a
        // literal position never compares against it.
        #expect(matcher.match("https://bank.example/pay/%FF") == nil)
        #expect(matcher.match("https://bank.example/%FF/1") == nil)

        // An undecodable query value is present but invalid for every type,
        // `String` included, so a route that reads it does not resolve. It is
        // never mistaken for a missing value, and never shifts a later one
        // into its place.
        #expect(matcher.match("https://bank.example/search?q=%FF") == nil)
        #expect(matcher.match("https://bank.example/page?n=%FF") == nil)
        #expect(matcher.match("https://bank.example/page?n=%FF&n=3") == nil)
        #expect(matcher.match("https://bank.example/page?n=3&n=%FF") == "3")
        #expect(matcher.match("https://bank.example/all?n=1&n=%FF&n=3") == "1,3")
        // The untyped accessor keeps reporting the empty string, as in 7.0.
        #expect(matcher.match("https://bank.example/raw?q=%FF") == "raw:")

        // Input the route never reads does not decide the match: a tracking
        // parameter in a legacy encoding, or a segment a wildcard swallows.
        #expect(matcher.match("https://bank.example/pay/1?utm_campaign=caf%E9") == "1")
        #expect(matcher.match("https://bank.example/pay/1?q=%C7%D1%B1%DB") == "1")
        #expect(matcher.match("https://bank.example/search?%FF=1") == "<none>")
        #expect(matcher.match("https://bank.example/files/%FF") == "files")
        #expect(matcher.match("https://bank.example/files/a/%FF?x=%FF") == "files")
    }

    @Test("Undecodable query items still count toward the item limit")
    func undecodableItemsCountTowardLimits() throws {
        let limits = DeepLinkInputLimits(maxQueryItems: 1)
        let url = try #require(URL(string: "https://bank.example/search?a=1&b=%FF"))
        #expect(limits.violation(for: url) == .queryItemCountExceeded(actual: 2, max: 1))
    }
}
