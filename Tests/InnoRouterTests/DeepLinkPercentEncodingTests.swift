// MARK: - DeepLinkPercentEncodingTests.swift
// InnoRouterTests - percent-encoded path component normalisation
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Testing
import InnoRouter

@Suite("DeepLink percent-encoding normalisation")
struct DeepLinkPercentEncodingTests {

    private enum DeepRoute: Route, Equatable {
        case detail(String)
        case home
    }

    @Test("Percent-encoded ASCII path component matches its decoded pattern")
    func testAsciiPercentEncodedPathMatches() throws {
        let matcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/hello world") { _ in .home }
        }

        let url = try #require(URL(string: "myapp://app/hello%20world"))
        let route = matcher.match(url)

        #expect(route == .home)
    }

    @Test("Percent-encoded UTF-8 (Korean) path component decodes correctly")
    func testKoreanPercentEncodedPathMatches() throws {
        let matcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/안녕") { _ in .home }
        }

        // %EC%95%88%EB%85%95 == "안녕" in UTF-8
        let url = try #require(URL(string: "myapp://app/%EC%95%88%EB%85%95"))
        let route = matcher.match(url)

        #expect(route == .home)
    }

    @Test("Percent-encoded parameter value is decoded into the handler")
    func testParameterPercentDecoding() throws {
        let matcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/detail/:id") { params in
                params.firstValue(forName: "id").map(DeepRoute.detail)
            }
        }

        let url = try #require(URL(string: "myapp://app/detail/hello%20world"))
        let route = matcher.match(url)

        #expect(route == .detail("hello world"))
    }

    @Test("Already-decoded path components remain unchanged")
    func testDecodedPathComponentRoundtrip() throws {
        let matcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/home") { _ in .home }
        }

        let url = try #require(URL(string: "myapp://app/home"))
        let route = matcher.match(url)

        #expect(route == .home)
    }

    @Test("Percent-encoded slash stays inside one path segment")
    func testPercentEncodedSlashPreservesSegmentBoundary() throws {
        let twoSegmentMatcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/a/b") { _ in .home }
        }
        let oneSegmentMatcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/:id") { parameters in
                parameters.firstValue(forName: "id").map(DeepRoute.detail)
            }
        }
        let url = try #require(URL(string: "myapp://app/a%2Fb"))

        #expect(twoSegmentMatcher.match(url) == nil)
        #expect(oneSegmentMatcher.match(url) == .detail("a/b"))
    }

    @Test("Path and query values are percent-decoded exactly once")
    func testPathAndQueryValuesDecodeExactlyOnce() throws {
        let matcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/:path") { parameters in
                guard let path = parameters.firstValue(forName: "path"),
                      let doubleEncodedQuery = parameters.firstValue(forName: "double"),
                      let encodedQuery = parameters.firstValue(forName: "single")
                else {
                    return nil
                }
                return .detail("\(path)|\(doubleEncodedQuery)|\(encodedQuery)")
            }
        }
        let url = try #require(URL(string: "myapp://app/a%252Fb?double=a%252Fb&single=a%2Fb"))

        #expect(matcher.match(url) == .detail("a%2Fb|a%2Fb|a/b"))
    }

    @Test("Path segment limits and matching use the same encoded boundaries")
    func testPathSegmentLimitUsesEncodedBoundaries() throws {
        let matcher = DeepLinkMatcher<DeepRoute>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: .init(maxPathSegments: 1)
            )
        ) {
            DeepLinkMapping("/a/b") { _ in .home }
            DeepLinkMapping("/:id") { parameters in
                parameters.firstValue(forName: "id").map(DeepRoute.detail)
            }
        }
        let encodedSlashURL = try #require(URL(string: "myapp://app/a%2Fb"))
        let literalSlashURL = try #require(URL(string: "myapp://app/a/b"))

        #expect(matcher.match(encodedSlashURL) == .detail("a/b"))
        #expect(matcher.match(literalSlashURL) == nil)
    }

    @Test("Percent-encoded dot segments remain literal captured values")
    func testPercentEncodedDotSegmentsRemainLiteral() throws {
        let matcher = DeepLinkMatcher<DeepRoute> {
            DeepLinkMapping("/:first/:second/x") { parameters in
                guard let first = parameters.firstValue(forName: "first"),
                      let second = parameters.firstValue(forName: "second")
                else {
                    return nil
                }
                return .detail("\(first)|\(second)")
            }
        }
        let url = try #require(URL(string: "myapp://app/%2E/%2E%2E/x"))

        #expect(matcher.match(url) == .detail(".|.."))
    }
}
