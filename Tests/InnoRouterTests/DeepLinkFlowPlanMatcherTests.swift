// MARK: - DeepLinkFlowPlanMatcherTests.swift
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
@Suite("DeepLinkMatcher FlowPlan Tests")
struct DeepLinkFlowPlanMatcherTests {

    private func makeMatcher() -> DeepLinkMatcher<FlowPlan<MatcherRoute>> {
        DeepLinkMatcher<FlowPlan<MatcherRoute>> {
            DeepLinkMapping("/home") { _ in
                FlowPlan(steps: [.push(.home)])
            }
            DeepLinkMapping("/home/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
            }
            DeepLinkMapping("/home/detail/:id/comments/:cid") { params in
                guard let id = params.firstValue(forName: "id"),
                      let cid = params.firstValue(forName: "cid") else { return nil }
                return FlowPlan(steps: [
                    .push(.home),
                    .push(.detail(id: id)),
                    .push(.comments(id: cid))
                ])
            }
            DeepLinkMapping("/onboarding/privacy") { _ in
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
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>> {
            // This mapping declines to build a plan.
            DeepLinkMapping("/detail/:id") { _ in nil }
            // Later mapping with same pattern still matches because
            // the first one fell through.
            DeepLinkMapping("/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.detail(id: id))])
            }
        }
        #expect(matcher.match("myapp://app/detail/99") == FlowPlan(steps: [.push(.detail(id: "99"))]))
    }

    @Test("Result builder accepts dynamically assembled mappings")
    func dynamicMappings() {
        let mappings: [DeepLinkMapping<FlowPlan<MatcherRoute>>] = [
            DeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) }
        ]
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>> {
            mappings
        }
        #expect(matcher.match("myapp://app/home") == FlowPlan(steps: [.push(.home)]))
    }

    @Test("Result builder accepts optional and either mappings")
    func conditionalMappings() {
        let includePrivacy = true
        let preferHome = false
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>> {
            if includePrivacy {
                DeepLinkMapping("/privacy") { _ in
                    FlowPlan(steps: [.sheet(.privacyPolicy)])
                }
            }
            if preferHome {
                DeepLinkMapping("/choice") { _ in
                    FlowPlan(steps: [.push(.home)])
                }
            } else {
                DeepLinkMapping("/choice") { _ in
                    FlowPlan(steps: [.push(.privacyPolicy)])
                }
            }
        }

        #expect(matcher.match("myapp://app/privacy") == FlowPlan(steps: [.sheet(.privacyPolicy)]))
        #expect(matcher.match("myapp://app/choice") == FlowPlan(steps: [.push(.privacyPolicy)]))
    }

    @Test("Repeated path parameters use DeepLinkPattern append semantics")
    func repeatedPathParametersAppend() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>> {
            DeepLinkMapping("/compare/:id/:id") { params in
                FlowPlan(steps: [.push(.compare(ids: params.values(forName: "id")))])
            }
        }

        #expect(
            matcher.match("myapp://app/compare/a/b?id=c&id=d")
            == FlowPlan(steps: [.push(.compare(ids: ["a", "b", "c", "d"]))])
        )
    }

    @Test("Route and FlowPlan output specializations keep encoded-path and diagnostic parity")
    func routeAndFlowMatcherParity() {
        let configuration = DeepLinkMatcherConfiguration(diagnosticsMode: .disabled)
        let routeMatcher = DeepLinkMatcher<MatcherRoute>(configuration: configuration) {
            DeepLinkMapping("/hello world/:id") { params in
                params.firstValue(forName: "id").map(MatcherRoute.detail(id:))
            }
            DeepLinkMapping("/hello world/:slug") { _ in .privacyPolicy }
        }
        let flowMatcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(configuration: configuration) {
            DeepLinkMapping("/hello world/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.detail(id: id))])
            }
            DeepLinkMapping("/hello world/:slug") { _ in
                FlowPlan(steps: [.push(.privacyPolicy)])
            }
        }

        let url = "myapp://app/hello%20world/42"
        #expect(routeMatcher.match(url) == .detail(id: "42"))
        #expect(flowMatcher.match(url) == FlowPlan(steps: [.push(.detail(id: "42"))]))
        #expect(routeMatcher.diagnostics == flowMatcher.diagnostics)
    }

    @Test("DeepLinkMatcher surfaces duplicate pattern diagnostics")
    func duplicatePatternDiagnostics() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) }
            DeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
        }

        #expect(
            matcher.diagnostics == [
                .duplicatePattern(pattern: "/home", firstIndex: 0, duplicateIndex: 1)
            ]
        )
    }

    @Test("DeepLinkMatcher surfaces wildcard shadowing diagnostics")
    func wildcardShadowingDiagnostics() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/api/*") { _ in FlowPlan(steps: [.push(.home)]) }
            DeepLinkMapping("/api/users") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
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

    @Test("DeepLinkMatcher surfaces non-terminal wildcard diagnostics")
    func nonTerminalWildcardDiagnostics() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/api/*/users") { _ in FlowPlan(steps: [.push(.home)]) }
            DeepLinkMapping("/api/users") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
        }

        #expect(
            matcher.diagnostics == [
                .nonTerminalWildcard(pattern: "/api/*/users", index: 1)
            ]
        )
        #expect(matcher.match("myapp://app/api/v1/users") == nil)
    }

    @Test("DeepLinkMatcher surfaces parameter shadowing diagnostics")
    func parameterShadowingDiagnostics() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/products/:id") { _ in FlowPlan(steps: [.push(.detail(id: "generic"))]) }
            DeepLinkMapping("/products/featured") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
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

    @Test("DeepLinkMatcher surfaces invalid parameter name diagnostics")
    func invalidParameterNameDiagnostics() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/detail/:1id") { _ in FlowPlan(steps: [.push(.detail(id: "invalid"))]) }
        }

        #expect(
            matcher.diagnostics == [
                .invalidParameterName(pattern: "/detail/:1id", index: 1, name: "1id")
            ]
        )
        #expect(matcher.match("myapp://app/detail/99") == nil)
    }

    @Test("DeepLinkMatcher input limits reject before matching")
    func inputLimitsRejectBeforeMatching() {
        let matcher = DeepLinkMatcher<FlowPlan<MatcherRoute>>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
            )
        ) {
            DeepLinkMapping("/compare/:id") { params in
                FlowPlan(steps: [.push(.compare(ids: params.values(forName: "id")))])
            }
        }

        #expect(matcher.match("myapp://app/compare/a?id=b&id=c") == nil)
    }

    @Test("DeepLinkMatcher strict init throws on duplicate patterns")
    func strictInitThrowsOnDuplicatePattern() {
        do {
            _ = try DeepLinkMatcher<FlowPlan<MatcherRoute>>(strict: ()) {
                DeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) }
                DeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.privacyPolicy)]) }
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

    @Test("DeepLinkMatcher strict init throws on invalid parameter name")
    func strictInitThrowsOnInvalidParameterName() {
        do {
            _ = try DeepLinkMatcher<FlowPlan<MatcherRoute>>(strict: ()) {
                DeepLinkMapping("/detail/:1id") { _ in FlowPlan(steps: [.push(.detail(id: "invalid"))]) }
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

    @Test("DeepLinkMatcher strict builder accepts dynamic mappings")
    func strictBuilderAcceptsDynamicMappings() throws {
        let mappings: [DeepLinkMapping<FlowPlan<MatcherRoute>>] = [
            DeepLinkMapping("/home") { _ in FlowPlan(steps: [.push(.home)]) },
            DeepLinkMapping("/privacy") { _ in FlowPlan(steps: [.sheet(.privacyPolicy)]) }
        ]
        let matcher = try DeepLinkMatcher<FlowPlan<MatcherRoute>>(strict: ()) {
            for mapping in mappings {
                mapping
            }
        }

        #expect(matcher.diagnostics.isEmpty)
        #expect(matcher.match("myapp://app/home") == FlowPlan(steps: [.push(.home)]))
    }
}
