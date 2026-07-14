// MARK: - FlowDeepLinkMatcherTests.swift
// InnoRouterTests - URL → FlowPlan<R>? composite matching
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouter
import InnoRouterDeepLink

private enum MatcherRoute: Route {
    case home
    case detail(id: String)
    case comments(id: String)
    case privacyPolicy
    case compare(ids: [String])
}

/// Pattern matching keys off the URL's **path** (not the
/// scheme/host). Use hosts like `app` and paths like `/home/detail/42`.
@Suite("FlowDeepLinkMatcher Tests")
struct FlowDeepLinkMatcherTests {

    private func makeMatcher() -> FlowDeepLinkMatcher<MatcherRoute> {
        FlowDeepLinkMatcher<MatcherRoute> {
            FlowDeepLinkMapping("/home") { _ in
                FlowPlan(steps: [.push(.home)])
            }
            FlowDeepLinkMapping("/home/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
            }
            FlowDeepLinkMapping("/home/detail/:id/comments/:cid") { params in
                guard let id = params.firstValue(forName: "id"),
                      let cid = params.firstValue(forName: "cid") else { return nil }
                return FlowPlan(steps: [
                    .push(.home),
                    .push(.detail(id: id)),
                    .push(.comments(id: cid))
                ])
            }
            FlowDeepLinkMapping("/onboarding/privacy") { _ in
                FlowPlan(steps: [.sheet(.privacyPolicy)])
            }
        }
    }

    @Test("Single-path pattern matches and builds a single-step plan")
    func singleRoutePattern() {
        let matcher = makeMatcher()
        let plan = matcher.match("myapp://app/home")
        #expect(plan == FlowPlan(steps: [.push(.home)]))
    }

    @Test("Multi-segment pattern extracts :id and builds a two-push plan")
    func multiSegmentPattern() {
        let matcher = makeMatcher()
        let plan = matcher.match("myapp://app/home/detail/42")
        #expect(plan == FlowPlan(steps: [.push(.home), .push(.detail(id: "42"))]))
    }

    @Test("Deep multi-segment pattern preserves parameter extraction order")
    func deepMultiSegmentPattern() {
        let matcher = makeMatcher()
        let plan = matcher.match("myapp://app/home/detail/42/comments/7")
        #expect(plan == FlowPlan(steps: [
            .push(.home),
            .push(.detail(id: "42")),
            .push(.comments(id: "7"))
        ]))
    }

    @Test("Modal-terminal pattern produces a .sheet tail in FlowPlan")
    func modalTerminalPattern() {
        let matcher = makeMatcher()
        let plan = matcher.match("myapp://app/onboarding/privacy")
        #expect(plan == FlowPlan(steps: [.sheet(.privacyPolicy)]))
    }

    @Test("Unmatched URL returns nil")
    func noMatch() {
        let matcher = makeMatcher()
        #expect(matcher.match("myapp://app/nonexistent") == nil)
    }

    @Test("Malformed URL string returns nil")
    func malformedString() {
        let matcher = makeMatcher()
        #expect(matcher.match("not a url") == nil)
    }

    @Test("Handler returning nil allows fallthrough to the next mapping")
    func handlerFallthrough() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute> {
            // This mapping declines to build a plan.
            FlowDeepLinkMapping("/detail/:id") { _ in nil }
            // Later mapping with same pattern still matches because
            // the first one fell through.
            FlowDeepLinkMapping("/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.detail(id: id))])
            }
        }
        #expect(matcher.match("myapp://app/detail/99") == FlowPlan(steps: [.push(.detail(id: "99"))]))
    }

    @Test("Init(mappings:) non-builder accepts a direct array")
    func arrayInit() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(mappings: [
            FlowDeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) }
        ])
        #expect(matcher.match("myapp://app/home") == FlowPlan(steps: [.push(.home)]))
    }

    @Test("Repeated path parameters use DeepLinkPattern append semantics")
    func repeatedPathParametersAppend() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute> {
            FlowDeepLinkMapping("/compare/:id/:id") { params in
                FlowPlan(steps: [.push(.compare(ids: params.values(forName: "id")))])
            }
        }

        #expect(
            matcher.match("myapp://app/compare/a/b?id=c&id=d")
            == FlowPlan(steps: [.push(.compare(ids: ["a", "b", "c", "d"]))])
        )
    }

    @Test("Route and flow matchers keep encoded-path and diagnostic parity")
    func routeAndFlowMatcherParity() {
        let configuration = DeepLinkMatcherConfiguration(diagnosticsMode: .disabled)
        let routeMatcher = DeepLinkMatcher<MatcherRoute>(configuration: configuration) {
            DeepLinkMapping("/hello world/:id") { params in
                params.firstValue(forName: "id").map(MatcherRoute.detail(id:))
            }
            DeepLinkMapping("/hello world/:slug") { _ in .privacyPolicy }
        }
        let flowMatcher = FlowDeepLinkMatcher<MatcherRoute>(configuration: configuration) {
            FlowDeepLinkMapping("/hello world/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.detail(id: id))])
            }
            FlowDeepLinkMapping("/hello world/:slug") { _ in
                FlowPlan(steps: [.push(.privacyPolicy)])
            }
        }

        let url = "myapp://app/hello%20world/42"
        #expect(routeMatcher.match(url) == .detail(id: "42"))
        #expect(flowMatcher.match(url) == FlowPlan(steps: [.push(.detail(id: "42"))]))
        #expect(routeMatcher.diagnostics == flowMatcher.diagnostics)
    }

    @Test("FlowDeepLinkMatcher surfaces duplicate pattern diagnostics")
    func duplicatePatternDiagnostics() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            FlowDeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) }
            FlowDeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
        }

        #expect(
            matcher.diagnostics == [
                .duplicatePattern(pattern: "/home", firstIndex: 0, duplicateIndex: 1)
            ]
        )
    }

    @Test("FlowDeepLinkMatcher surfaces wildcard shadowing diagnostics")
    func wildcardShadowingDiagnostics() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            FlowDeepLinkMapping("/api/*") { _ in FlowPlan(steps: [.push(.home)]) }
            FlowDeepLinkMapping("/api/users") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
        }

        #expect(
            matcher.diagnostics == [
                .wildcardShadowing(
                    pattern: "/api/*",
                    index: 0,
                    shadowedPattern: "/api/users",
                    shadowedIndex: 1
                )
            ]
        )
    }

    @Test("FlowDeepLinkMatcher surfaces non-terminal wildcard diagnostics")
    func nonTerminalWildcardDiagnostics() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            FlowDeepLinkMapping("/api/*/users") { _ in FlowPlan(steps: [.push(.home)]) }
            FlowDeepLinkMapping("/api/users") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
        }

        #expect(
            matcher.diagnostics == [
                .nonTerminalWildcard(pattern: "/api/*/users", index: 1)
            ]
        )
        #expect(matcher.match("myapp://app/api/v1/users") == nil)
    }

    @Test("FlowDeepLinkMatcher surfaces parameter shadowing diagnostics")
    func parameterShadowingDiagnostics() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            FlowDeepLinkMapping("/products/:id") { _ in FlowPlan(steps: [.push(.detail(id: "generic"))]) }
            FlowDeepLinkMapping("/products/featured") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
        }

        #expect(
            matcher.diagnostics == [
                .parameterShadowing(
                    pattern: "/products/:param",
                    index: 0,
                    shadowedPattern: "/products/featured",
                    shadowedIndex: 1
                )
            ]
        )
    }

    @Test("FlowDeepLinkMatcher surfaces invalid parameter name diagnostics")
    func invalidParameterNameDiagnostics() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            FlowDeepLinkMapping("/detail/:1id") { _ in FlowPlan(steps: [.push(.detail(id: "invalid"))]) }
        }

        #expect(
            matcher.diagnostics == [
                .invalidParameterName(pattern: "/detail/:1id", index: 1, name: "1id")
            ]
        )
        #expect(matcher.match("myapp://app/detail/99") == nil)
    }

    @Test("FlowDeepLinkMatcher input limits reject before matching")
    func inputLimitsRejectBeforeMatching() {
        let matcher = FlowDeepLinkMatcher<MatcherRoute>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
            )
        ) {
            FlowDeepLinkMapping("/compare/:id") { params in
                FlowPlan(steps: [.push(.compare(ids: params.values(forName: "id")))])
            }
        }

        #expect(matcher.match("myapp://app/compare/a?id=b&id=c") == nil)
    }

    @Test("FlowDeepLinkMatcher strict init throws on duplicate patterns")
    func strictInitThrowsOnDuplicatePattern() {
        do {
            _ = try FlowDeepLinkMatcher<MatcherRoute>(strict: ()) {
                FlowDeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) }
                FlowDeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
            }
            Issue.record("Expected DeepLinkMatcherStrictError")
        } catch let error as DeepLinkMatcherStrictError {
            #expect(
                error.diagnostics == [
                    .duplicatePattern(pattern: "/home", firstIndex: 0, duplicateIndex: 1)
                ]
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("FlowDeepLinkMatcher strict init throws on invalid parameter name")
    func strictInitThrowsOnInvalidParameterName() {
        do {
            _ = try FlowDeepLinkMatcher<MatcherRoute>(strict: ()) {
                FlowDeepLinkMapping("/detail/:1id") { _ in FlowPlan(steps: [.push(.detail(id: "invalid"))]) }
            }
            Issue.record("Expected DeepLinkMatcherStrictError")
        } catch let error as DeepLinkMatcherStrictError {
            #expect(
                error.diagnostics == [
                    .invalidParameterName(pattern: "/detail/:1id", index: 1, name: "1id")
                ]
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("FlowDeepLinkMatcher strict array init succeeds with clean mappings")
    func strictArrayInitSucceedsWithCleanMappings() throws {
        let matcher = try FlowDeepLinkMatcher<MatcherRoute>(
            strict: (),
            mappings: [
                FlowDeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) },
                FlowDeepLinkMapping("/privacy") { _ in FlowPlan(steps: [.sheet(.privacyPolicy)]) }
            ]
        )

        #expect(matcher.diagnostics.isEmpty)
        #expect(matcher.match("myapp://app/home") == FlowPlan(steps: [.push(.home)]))
    }
}
