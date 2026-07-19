// MARK: - DeepLinkCoreTests.swift
// InnoRouter Tests
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import Observation
import OSLog
import Synchronization
import SwiftUI
import InnoRouter
import InnoRouterEffects
@testable import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

// MARK: - DeepLink Tests

@Suite("DeepLink Tests")
struct DeepLinkTests {

    @Test("DeepLinkParser parses URL correctly")
    func testParser() {
        let parsed = DeepLinkParser.parse("myapp://example.com/products/123?category=electronics")!

        #expect(parsed.scheme == "myapp")
        #expect(parsed.host == "example.com")
        #expect(parsed.path == ["products", "123"])
        #expect(parsed.queryItems["category"] == ["electronics"])
        #expect(parsed.queryItems["category"]?.first == "electronics")
    }

    @Test("DeepLinkParser keeps duplicate query values without crashing")
    func testParserDuplicateQueries() {
        let parsed = DeepLinkParser.parse("myapp://example.com/products/123?tag=a&tag=b&tag=c")!
        #expect(parsed.queryItems["tag"] == ["a", "b", "c"])
        #expect(parsed.queryItems["tag"]?.first == "a")
    }

    @Test("DeepLinkParser keeps flag-style query items as empty strings")
    func testParserFlagQueryItem() {
        let parsed = DeepLinkParser.parse("myapp://example.com/products/123?debug&tag=a")!
        #expect(parsed.queryItems["debug"] == [""])
        #expect(parsed.queryItems["debug"]?.first == "")
        #expect(parsed.queryItems["tag"] == ["a"])
    }

    @Test("DeepLinkParameters preserves duplicate query value order")
    func testDeepLinkParametersValueOrder() {
        let parameters = DeepLinkParameters(valuesByName: ["tag": ["a", "b", "c"]])
        #expect(parameters.values(forName: "tag") == ["a", "b", "c"])
        #expect(parameters.firstValue(forName: "tag") == "a")
    }

    @Test("DeepLinkParameters parses typed values")
    func testDeepLinkParametersTypedValues() {
        let uuid = UUID(uuidString: "9D5C7829-CC7F-4EB7-A701-F13DF35C8A26")!
        let parameters = DeepLinkParameters(valuesByName: [
            "id": ["42", "not-an-int", "7"],
            "enabled": ["true"],
            "uuid": [uuid.uuidString],
            "invalidUUID": ["nope"],
        ])

        #expect(parameters.firstValue(forName: "id", as: Int.self) == 42)
        #expect(parameters.values(forName: "id", as: Int.self) == [42, 7])
        #expect(parameters.firstValue(forName: "enabled", as: Bool.self) == true)
        #expect(parameters.firstValue(forName: "uuid", as: UUID.self) == uuid)
        #expect(parameters.firstValue(forName: "invalidUUID", as: UUID.self) == nil)
    }

    @Test("Path parameters take precedence when query uses same key")
    func testPatternMergeCollisionOrder() {
        let pattern = DeepLinkPattern("/products/:id")
        let parsed = DeepLinkParser.parse("myapp://example.com/products/123?id=override&id=final")!

        guard let result = pattern.match(parsed) else {
            Issue.record("Expected pattern match")
            return
        }

        #expect(result.parameters["id"] == ["123", "override", "final"])

        let parameters = DeepLinkParameters(valuesByName: result.parameters)
        #expect(parameters.firstValue(forName: "id") == "123")
    }

    @Test("Repeated path parameters append values in declaration order")
    func testRepeatedPathParametersAppend() {
        let pattern = DeepLinkPattern("/compare/:id/:id")

        guard let result = pattern.match("/compare/a/b") else {
            Issue.record("Expected pattern match")
            return
        }

        #expect(result.parameters["id"] == ["a", "b"])
    }

    @Test("Repeated path parameters append before query values")
    func testRepeatedPathParametersAppendBeforeQueryValues() {
        let pattern = DeepLinkPattern("/compare/:id/:id")
        let parsed = DeepLinkParser.parse("myapp://example.com/compare/a/b?id=c&id=d")!

        guard let result = pattern.match(parsed) else {
            Issue.record("Expected pattern match")
            return
        }

        #expect(result.parameters["id"] == ["a", "b", "c", "d"])
    }

    @Test("DeepLinkPattern matches literal path")
    func testPatternLiteral() {
        let pattern = DeepLinkPattern("/home")

        let result = pattern.match("/home")
        #expect(result != nil)
        #expect(result?.parameters.isEmpty == true)

        let noMatch = pattern.match("/settings")
        #expect(noMatch == nil)
    }

    @Test("DeepLinkPattern matches parameter")
    func testPatternParameter() {
        let pattern = DeepLinkPattern("/products/:id")

        let result = pattern.match("/products/123")
        #expect(result != nil)
        #expect(result?.parameters["id"] == ["123"])
    }

    @Test("DeepLinkPattern matches wildcard")
    func testPatternWildcard() {
        let pattern = DeepLinkPattern("/api/*")

        let result = pattern.match("/api/v1/users/123")
        #expect(result != nil)
    }

    @Test("DeepLinkPattern rejects non-terminal wildcard")
    func testPatternRejectsNonTerminalWildcard() {
        let pattern = DeepLinkPattern("/api/*/users")

        #expect(pattern.match("/api/v1/users") == nil)
        #expect(pattern.match("/api/v1/other") == nil)
    }

    @Test("DeepLinkMatcher finds matching route")
    func testMatcher() {
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/home") { _ in .home }
            DeepLinkMapping("/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return .detail(id: id)
            }
            DeepLinkMapping("/settings") { _ in .settings }
        }

        let url1 = URL(string: "myapp://app/home")!
        #expect(matcher.match(url1) == .home)

        let url2 = URL(string: "myapp://app/detail/456")!
        #expect(matcher.match(url2) == .detail(id: "456"))

        let url3 = URL(string: "myapp://app/unknown")!
        #expect(matcher.match(url3) == nil)
    }

    @Test("DeepLinkMatcher falls through when a matching handler returns nil")
    func testMatcherHandlerFallthrough() {
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/detail/:id") { _ in nil }
            DeepLinkMapping("/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return .detail(id: id)
            }
        }

        #expect(matcher.match("myapp://app/detail/99") == .detail(id: "99"))
    }

    @Test("DeepLinkMatcher preserves ordered typed fallbacks for one pattern")
    func testMatcherTypedFallthrough() {
        let matcher = DeepLinkMatcher<String>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/items/:value") { parameters in
                guard parameters.firstValue(
                    forName: "value",
                    as: UUID.self
                ) != nil else {
                    return nil
                }
                return "uuid"
            }
            DeepLinkMapping("/items/:value") { parameters in
                guard parameters.firstValue(
                    forName: "value",
                    as: Int.self
                ) != nil else {
                    return nil
                }
                return "integer"
            }
            DeepLinkMapping("/items/:value") { parameters in
                parameters.firstValue(forName: "value", as: String.self)
            }
        }

        #expect(
            matcher.match("myapp://app/items/550e8400-e29b-41d4-a716-446655440000") ==
                "uuid"
        )
        #expect(matcher.match("myapp://app/items/42") == "integer")
        #expect(matcher.match("myapp://app/items/books") == "books")
    }

    @Test("DeepLinkMatcher supports non-route Sendable outputs")
    func testMatcherGenericOutput() {
        let matcher = DeepLinkMatcher<String> {
            DeepLinkMapping("/message/:value") { parameters in
                parameters.firstValue(forName: "value")
            }
        }

        #expect(matcher.match("myapp://app/message/hello") == "hello")
    }

    @Test("DeepLinkMatcher surfaces duplicate pattern diagnostics")
    func testMatcherDuplicatePatternDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/home") { _ in .home }
            DeepLinkMapping("/home") { _ in .settings }
        }

        #expect(
            matcher.diagnostics == [
                .duplicatePattern(pattern: "/home", firstIndex: 0, duplicateIndex: 1)
            ]
        )
    }

    @Test("DeepLinkMatcher surfaces wildcard shadowing diagnostics")
    func testMatcherWildcardShadowingDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/api/*") { _ in .home }
            DeepLinkMapping("/api/users") { _ in .settings }
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
    func testMatcherNonTerminalWildcardDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/api/*/users") { _ in .home }
            DeepLinkMapping("/api/users") { _ in .settings }
        }

        #expect(
            matcher.diagnostics == [
                .nonTerminalWildcard(pattern: "/api/*/users", index: 1)
            ]
        )
        #expect(matcher.match(URL(string: "myapp://app/api/v1/users")!) == nil)
    }

    @Test("DeepLinkMatcher does not layer shadow diagnostics on invalid wildcard patterns")
    func testMatcherNonTerminalWildcardDiagnosticsDoNotCascade() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/api/*") { _ in .home }
            DeepLinkMapping("/api/*/users") { _ in .settings }
        }

        #expect(
            matcher.diagnostics == [
                .nonTerminalWildcard(pattern: "/api/*/users", index: 1)
            ]
        )
    }

    @Test("DeepLinkMatcher surfaces parameter shadowing diagnostics")
    func testMatcherParameterShadowingDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/products/:id") { _ in .detail(id: "generic") }
            DeepLinkMapping("/products/featured") { _ in .settings }
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
    func testMatcherInvalidParameterNameDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/detail/:1id") { _ in .detail(id: "invalid") }
        }

        #expect(
            matcher.diagnostics == [
                .invalidParameterName(pattern: "/detail/:1id", index: 1, name: "1id")
            ]
        )
        #expect(matcher.match(URL(string: "myapp://app/detail/456")!) == nil)
    }

    @Test("Invalid parameter patterns do not shadow or duplicate valid mappings")
    func testInvalidParameterDiagnosticsDoNotCascade() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/:1id") { _ in .detail(id: "invalid") }
            DeepLinkMapping("/home") { _ in .home }
            DeepLinkMapping("/:slug") { parameters in
                parameters.firstValue(forName: "slug").map(TestRoute.detail(id:))
            }
        }

        #expect(
            matcher.diagnostics == [
                .invalidParameterName(pattern: "/:1id", index: 0, name: "1id")
            ]
        )
        #expect(matcher.match("myapp://app/home") == .home)
        #expect(matcher.match("myapp://app/profile") == .detail(id: "profile"))
    }

    @Test("Invalid patterns are excluded without hiding valid shadow diagnostics")
    func testInvalidParameterFilteringPreservesValidShadowDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/*") { _ in .home }
            DeepLinkMapping("/:1id") { _ in .detail(id: "invalid") }
            DeepLinkMapping("/home") { _ in .settings }
        }

        #expect(
            matcher.diagnostics == [
                .invalidParameterName(pattern: "/:1id", index: 0, name: "1id"),
                .wildcardShadowing(
                    pattern: "/*",
                    index: 0,
                    shadowedPattern: "/home",
                    shadowedIndex: 2
                ),
            ]
        )
    }

    @Test("DeepLinkMatcher input limits reject before matching")
    func testMatcherInputLimitsRejectBeforeMatching() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxURLLength: 20)
            )
        ) {
            DeepLinkMapping("/detail/:id") { _ in .detail(id: "matched") }
        }

        #expect(matcher.match(URL(string: "myapp://app/detail/456")!) == nil)
    }

    @Test("DeepLinkMatcher treats renamed parameters as equivalent structure")
    func testMatcherParameterNameOnlyShadowingDiagnostics() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/users/:id") { _ in .detail(id: "id") }
            DeepLinkMapping("/users/:slug") { _ in .detail(id: "slug") }
        }

        #expect(
            matcher.diagnostics == [
                .duplicatePattern(pattern: "/users/:param", firstIndex: 0, duplicateIndex: 1)
            ]
        )
    }

    @Test("DeepLinkMatcher default configuration emits debug warnings")
    func testMatcherDefaultConfigurationIncludesLogger() {
        let configuration = DeepLinkMatcherConfiguration.default

        #expect(configuration.diagnosticsMode == .debugWarnings)
        #expect(configuration.logger != nil)
    }

    @Test("DeepLinkMatcher debug warnings remain non-fatal")
    func testMatcherDebugWarningsDoNotAssert() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(
                diagnosticsMode: .debugWarnings,
                logger: Logger(subsystem: "InnoRouterTests", category: "DeepLinkMatcher")
            )
        ) {
            DeepLinkMapping("/products/:id") { _ in .detail(id: "generic") }
            DeepLinkMapping("/products/featured") { _ in .settings }
        }

        #expect(matcher.diagnostics.count == 1)
    }

    @Test("DeepLinkMatcher diagnostics do not change declaration-order precedence")
    func testMatcherDiagnosticsDoNotAffectMatchingPrecedence() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/products/:id") { _ in .detail(id: "generic") }
            DeepLinkMapping("/products/featured") { _ in .settings }
        }

        let matched = matcher.match(URL(string: "myapp://app/products/featured")!)

        #expect(matched == .detail(id: "generic"))
        #expect(matcher.diagnostics.count == 1)
    }

    @Test("DeepLinkPipeline rejected reason is schemeNotAllowed")
    func testPipelineRejectsSchemeWithReason() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            originPolicy: .allowlisted(
                schemes: ["MYAPP"],
                hosts: ["MYAPP.COM"]
            ),
            customResolver: { _ in .home }
        )
        let url = URL(string: "https://myapp.com/home")!

        let decision = pipeline.decide(for: url)
        guard case .rejected(let reason) = decision else {
            Issue.record("Expected rejected decision")
            return
        }
        #expect(reason == .schemeNotAllowed(actualScheme: "https"))
    }

    @Test("DeepLinkPipeline rejected reason is hostNotAllowed")
    func testPipelineRejectsHostWithReason() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            originPolicy: .allowlisted(
                schemes: ["myapp"],
                hosts: ["myapp.com"]
            ),
            customResolver: { _ in .home }
        )
        let url = URL(string: "myapp://other.com/home")!

        let decision = pipeline.decide(for: url)
        guard case .rejected(let reason) = decision else {
            Issue.record("Expected rejected decision")
            return
        }
        #expect(reason == .hostNotAllowed(actualHost: "other.com"))
    }

    @Test(
        "DeepLinkPipeline allowlisted origin rejects user information and ports",
        arguments: [
            "myapp://user@myapp.com/home",
            "myapp://user:password@myapp.com/home",
            "myapp://myapp.com:443/home",
        ]
    )
    func testPipelineRejectsNonCanonicalOrigin(urlString: String) {
        let pipeline = DeepLinkPipeline<TestRoute>(
            originPolicy: .allowlisted(
                schemes: ["myapp"],
                hosts: ["myapp.com"]
            ),
            customResolver: { _ in .home }
        )

        let decision = pipeline.decide(for: URL(string: urlString)!)

        #expect(decision == .rejected(reason: .hostNotAllowed(actualHost: "myapp.com")))
    }

    @Test("DeepLinkPipeline trusted in-process policy explicitly skips origin checks")
    func testPipelineTrustedInProcessOrigin() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            originPolicy: .trustedInProcess,
            customResolver: { _ in .home }
        )

        #expect(
            pipeline.decide(for: URL(string: "untrusted://user@outside.example:8080/home")!) ==
                .plan(NavigationPlan(commands: [.push(.home)]))
        )
    }

    @Test("DeepLinkPipeline rejected reason is inputLimitExceeded")
    func testPipelineRejectsInputLimitWithReason() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .home },
            inputLimits: DeepLinkInputLimits(maxPathSegments: 1)
        )
        let url = URL(string: "myapp://myapp.com/home/settings")!

        let decision = pipeline.decide(for: url)
        guard case .rejected(let reason) = decision else {
            Issue.record("Expected rejected decision")
            return
        }
        #expect(reason == .inputLimitExceeded(.pathSegmentCountExceeded(actual: 2, max: 1)))
    }

    @Test("DeepLinkPipeline preserves matcher input-limit rejection")
    func testPipelineRejectsMatcherInputLimitWithReason() {
        let handlerCallCount = Mutex(0)
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
            )
        ) {
            DeepLinkMapping("/home") { _ in
                handlerCallCount.withLock { $0 += 1 }
                return .home
            }
        }
        let pipeline = DeepLinkPipeline<TestRoute>(
            matcher: matcher,
            inputLimits: .unlimited
        )
        let url = URL(string: "myapp://myapp.com/home?a=1&b=2")!

        let decision = pipeline.decide(for: url)

        #expect(
            decision == .rejected(
                reason: .inputLimitExceeded(
                    .queryItemCountExceeded(actual: 2, max: 1)
                )
            )
        )
        #expect(handlerCallCount.withLock { $0 } == 0)
    }

    @Test("Strict DeepLinkMatcher preserves input-limit rejection in pipeline")
    func testPipelineRejectsStrictMatcherInputLimitWithReason() throws {
        let matcher = try DeepLinkMatcher<TestRoute>(
            strict: (),
            inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
        ) {
            DeepLinkMapping("/home") { _ in .home }
        }
        let pipeline = DeepLinkPipeline<TestRoute>(
            matcher: matcher,
            inputLimits: .unlimited
        )

        let decision = pipeline.decide(
            for: URL(string: "myapp://myapp.com/home?a=1&b=2")!
        )

        #expect(
            decision == .rejected(
                reason: .inputLimitExceeded(
                    .queryItemCountExceeded(actual: 2, max: 1)
                )
            )
        )
    }

    @Test("DeepLinkPipeline checks scheme before matcher input limits")
    func testPipelineRejectsSchemeBeforeMatcherInputLimit() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
            )
        ) {
            DeepLinkMapping("/home") { _ in .home }
        }
        let pipeline = DeepLinkPipeline<TestRoute>(
            allowedSchemes: ["myapp"],
            matcher: matcher,
            inputLimits: .unlimited
        )

        let decision = pipeline.decide(
            for: URL(string: "https://myapp.com/home?a=1&b=2")!
        )

        #expect(decision == .rejected(reason: .schemeNotAllowed(actualScheme: "https")))
    }

    @Test("DeepLinkPipeline checks its input limits before scheme")
    func testPipelineRejectsOwnInputLimitBeforeScheme() {
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/home") { _ in .home }
        }
        let pipeline = DeepLinkPipeline<TestRoute>(
            allowedSchemes: ["myapp"],
            matcher: matcher,
            inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
        )

        let decision = pipeline.decide(
            for: URL(string: "https://myapp.com/home?a=1&b=2")!
        )

        #expect(
            decision == .rejected(
                reason: .inputLimitExceeded(
                    .queryItemCountExceeded(actual: 2, max: 1)
                )
            )
        )
    }

    @Test("DeepLinkPipeline does not resolve or plan rejected URLs")
    func testPipelineRejectsBeforeCustomResolutionAndPlanning() {
        let resolverCallCount = Mutex(0)
        let plannerCallCount = Mutex(0)
        let pipeline = DeepLinkPipeline<TestRoute>(
            allowedSchemes: ["myapp"],
            customResolver: { _ in
                resolverCallCount.withLock { $0 += 1 }
                return .home
            },
            plan: { route in
                plannerCallCount.withLock { $0 += 1 }
                return NavigationPlan(commands: [.push(route)])
            }
        )

        let decision = pipeline.decide(for: URL(string: "https://myapp.com/home")!)

        #expect(decision == .rejected(reason: .schemeNotAllowed(actualScheme: "https")))
        #expect(resolverCallCount.withLock { $0 } == 0)
        #expect(plannerCallCount.withLock { $0 } == 0)
    }

    @Test("DeepLinkPipeline keeps URL in unhandled decision")
    func testPipelineUnhandledKeepsURL() {
        let pipeline = DeepLinkPipeline<TestRoute>(customResolver: { _ in nil })
        let url = URL(string: "myapp://myapp.com/missing")!

        let decision = pipeline.decide(for: url)
        guard case .unhandled(let unhandledURL) = decision else {
            Issue.record("Expected unhandled decision")
            return
        }
        #expect(unhandledURL == url)
    }

    @Test("DeepLinkPipeline matcher continues after a handler returns nil")
    func testPipelineMatcherFallsThroughNilHandler() {
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/home") { _ in nil as TestRoute? }
            DeepLinkMapping("/home") { _ in .home }
        }
        let pipeline = DeepLinkPipeline<TestRoute>(matcher: matcher)

        let decision = pipeline.decide(for: URL(string: "myapp://myapp.com/home")!)

        #expect(decision == .plan(NavigationPlan(commands: [.push(.home)])))
    }

    @Test("DeepLinkPipeline notRequired policy returns plan")
    func testPipelineNotRequiredPolicyReturnsPlan() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .settings },
            authenticationPolicy: .notRequired
        )
        let url = URL(string: "myapp://myapp.com/settings")!

        let decision = pipeline.decide(for: url)
        guard case .plan(let plan) = decision else {
            Issue.record("Expected plan decision")
            return
        }
        #expect(plan.commands == [.push(.settings)])
    }

    @Test("DeepLinkPipeline auth scans planned replace routes")
    func testPipelineAuthenticationScansPlannedReplaceRoutes() {
        let commands: [NavigationCommand<TestRoute>] = [
            .replace([.home, .settings])
        ]
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .home },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .settings },
                isAuthenticated: { false }
            ),
            plan: { _ in NavigationPlan(commands: commands) }
        )

        let decision = pipeline.decide(for: URL(string: "myapp://myapp.com/public")!)
        guard case .pending(let pending) = decision else {
            Issue.record("Expected pending decision")
            return
        }
        #expect(pending.route == .settings)
        #expect(pending.plan.commands == commands)
    }

    @Test("DeepLinkPipeline auth scans planned pushAll routes")
    func testPipelineAuthenticationScansPlannedPushAllRoutes() {
        let commands: [NavigationCommand<TestRoute>] = [
            .pushAll([.home, .settings])
        ]
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .home },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .settings },
                isAuthenticated: { false }
            ),
            plan: { _ in NavigationPlan(commands: commands) }
        )

        let decision = pipeline.decide(for: URL(string: "myapp://myapp.com/public")!)
        guard case .pending(let pending) = decision else {
            Issue.record("Expected pending decision")
            return
        }
        #expect(pending.route == .settings)
        #expect(pending.plan.commands == commands)
    }

    @Test("DeepLinkPipeline auth scans nested and fallback command routes")
    func testPipelineAuthenticationScansNestedAndFallbackRoutes() {
        let commands: [NavigationCommand<TestRoute>] = [
            .sequence([
                .push(.home),
                .whenCancelled(
                    .pushAll([.detail(id: "primary")]),
                    fallback: .popTo(.settings)
                )
            ])
        ]
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .home },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .settings },
                isAuthenticated: { false }
            ),
            plan: { _ in NavigationPlan(commands: commands) }
        )

        let decision = pipeline.decide(for: URL(string: "myapp://myapp.com/public")!)
        guard case .pending(let pending) = decision else {
            Issue.record("Expected pending decision")
            return
        }
        #expect(pending.route == .settings)
        #expect(pending.plan.commands == commands)
    }

    @Test("DeepLinkPipeline auth falls back to resolved route when plan has no routes")
    func testPipelineAuthenticationFallbackScansResolvedRoute() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .settings },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .settings },
                isAuthenticated: { false }
            ),
            plan: { _ in NavigationPlan(commands: [.pop]) }
        )

        let decision = pipeline.decide(for: URL(string: "myapp://myapp.com/secure")!)
        guard case .pending(let pending) = decision else {
            Issue.record("Expected pending decision")
            return
        }
        #expect(pending.route == .settings)
        #expect(pending.plan.commands == [.pop])
    }

    @Test("DeepLinkPipeline returns plan when protected planned route is authenticated")
    func testPipelineAuthenticationPassesWhenAuthenticated() {
        let commands: [NavigationCommand<TestRoute>] = [
            .replace([.home, .settings])
        ]
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .home },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .settings },
                isAuthenticated: { true }
            ),
            plan: { _ in NavigationPlan(commands: commands) }
        )

        let decision = pipeline.decide(for: URL(string: "myapp://myapp.com/public")!)
        guard case .plan(let plan) = decision else {
            Issue.record("Expected plan decision")
            return
        }
        #expect(plan.commands == commands)
    }
}
