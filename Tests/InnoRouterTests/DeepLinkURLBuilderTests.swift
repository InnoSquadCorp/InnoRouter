import Foundation
import Testing

import InnoRouterDeepLink

@Suite("DeepLink URL builder")
struct DeepLinkURLBuilderTests {
    @Test("Origin validation normalizes valid values and rejects malformed values")
    func originValidation() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "HTTPS", host: "APP.Example.COM")
        )

        #expect(origin.scheme == "https")
        #expect(origin.host == "app.example.com")
        #expect(DeepLinkOrigin(scheme: "1https", host: "app.example.com") == nil)
        #expect(DeepLinkOrigin(scheme: "https", host: "-app.example.com") == nil)
        #expect(DeepLinkOrigin(scheme: "https", host: "user@app.example.com") == nil)
        #expect(DeepLinkOrigin(scheme: "https", host: "127.0.0.999") == nil)
    }

    @Test("Builder encodes each path segment and leaves slash inside one value")
    func encodedPathSegments() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "https", host: "app.example.com")
        )
        let url = try #require(
            DeepLinkURLBuilder.makeURL(
                origin: origin,
                pattern: "/products/:id",
                parameters: [.init(name: "id", value: "한글/a b")]
            )
        )

        #expect(
            url.absoluteString ==
                "https://app.example.com/products/%ED%95%9C%EA%B8%80%2Fa%20b"
        )
    }

    @Test("Builder keeps declaration-order query items and omits nil values")
    func queryValues() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "https", host: "app.example.com")
        )
        let url = try #require(
            DeepLinkURLBuilder.makeURL(
                origin: origin,
                pattern: "/search",
                parameters: [
                    .init(name: "query", value: "a/b"),
                    .init(name: "page", value: "2"),
                    .init(name: "filter", value: nil),
                ]
            )
        )

        #expect(url.absoluteString == "https://app.example.com/search?query=a/b&page=2")
    }

    @Test("Builder writes query names in NFC, so a name given in another form reads back")
    func queryNamesAreComposed() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "https", host: "app.example.com")
        )
        let decomposed = try #require(
            DeepLinkURLBuilder.makeURL(
                origin: origin, pattern: "/search", parameters: [.init(name: "cafe\u{301}", value: "x")]
            )
        )
        #expect(decomposed.absoluteString == "https://app.example.com/search?caf%C3%A9=x")

        // A decomposed accent, a composition exclusion, and a singleton: the
        // resolver files each of these spellings under no name at all.
        for name in ["cafe\u{301}", "\u{0958}", "\u{212B}"] {
            let url = try #require(
                DeepLinkURLBuilder.makeURL(
                    origin: origin, pattern: "/search", parameters: [.init(name: name, value: "x")]
                )
            )
            // What a generated resolver does: read the label it rendered.
            let matcher = DeepLinkMatcher<String> {
                DeepLinkMapping("/search") { parameters in
                    parameters.firstValue(forName: name, as: String.self) ?? "<none>"
                }
            }
            let scalars = name.unicodeScalars.map { String($0.value, radix: 16) }
            #expect(matcher.match(url) == "x", "The built URL lost the value of \(scalars)")
        }
    }

    @Test("Builder rejects a missing path placeholder")
    func missingPathValue() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "https", host: "app.example.com")
        )

        #expect(
            DeepLinkURLBuilder.makeURL(
                origin: origin,
                pattern: "/products/:id"
            ) == nil
        )
    }

    @Test("Builder rejects an empty path placeholder")
    func emptyPathValue() throws {
        let origin = try #require(
            DeepLinkOrigin(scheme: "https", host: "app.example.com")
        )

        #expect(
            DeepLinkURLBuilder.makeURL(
                origin: origin,
                pattern: "/products/:id",
                parameters: [.init(name: "id", value: "")]
            ) == nil
        )
    }
}
