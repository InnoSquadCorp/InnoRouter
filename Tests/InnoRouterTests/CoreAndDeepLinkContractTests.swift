import Foundation
import Testing

import InnoRouterCore
import InnoRouterDeepLink

@Suite("Core value contracts")
struct CoreValueContractTests {
    private enum RouteFixture: String, Route, Codable {
        case home
        case detail
        case editor
        case settings
    }

    private enum Outer: Equatable, Sendable {
        case idle
        case inner(Inner)
    }

    private enum Inner: Equatable, Sendable {
        case value(Int)
        case empty
    }

    @Test("Hand-written case paths compose in both directions")
    func composedCasePaths() {
        let inner = CasePath<Outer, Inner>(
            embed: Outer.inner,
            extract: { root in
                guard case .inner(let value) = root else { return nil }
                return value
            }
        )
        let value = CasePath<Inner, Int>(
            embed: Inner.value,
            extract: { root in
                guard case .value(let value) = root else { return nil }
                return value
            }
        )
        let idle = CasePath<Outer, Void>(
            embed: { _ in .idle },
            extract: { root in root == .idle ? () : nil }
        )
        let composed = inner.appending(path: value)

        #expect(composed.embed(42) == .inner(.value(42)))
        #expect(composed.extract(.inner(.value(42))) == 42)
        #expect(composed.extract(.inner(.empty)) == nil)
        #expect(composed.extract(.idle) == nil)
        #expect(idle() == .idle)
    }

    @Test("Typed presentation requests are immutable value builders")
    func presentationRequestBuilders() {
        let options = RouterPresentationOptions(
            detents: [.medium, .large],
            selectedDetent: .medium,
            dragIndicator: .visible
        )
        let base = RouterPresentationRequest<RouteFixture, String>(route: .editor)
        let customized = base.style(.popover).options(options)

        #expect(base.style == .sheet)
        #expect(base.options == .init())
        #expect(customized.route == .editor)
        #expect(customized.style == .popover)
        #expect(customized.options == options)
        #expect(customized == RouterPresentationRequest(
            route: .editor,
            style: .popover,
            options: options
        ))
        #expect(Set([customized, customized]).count == 1)
    }

    @Test("Plan builder supports conditional, repeated, window, and immersive mutations")
    func completePlanBuilderSurface() throws {
        let includePresentation = true
        let useReplacementRoot = false
        let windowID = UUID()
        let plan = try RouterPlan<RouteFixture> {
            if useReplacementRoot {
                RouterPlanStep.root(.stack(path: [.settings]))
            } else {
                RouterPlanStep.stack([.home, .detail])
            }
            if includePresentation {
                RouterPlanStep.presentation(
                    .init(route: .editor, style: .sheet)
                )
            }
            RouterPlanStep.windows([
                .init(id: windowID, route: .settings),
            ])
            RouterPlanStep.immersiveSpace(
                .init(id: "studio", route: .detail)
            )
        }

        guard case .stack(let root) = plan.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        #expect(root.path == [.home, .detail])
        #expect(root.presentation?.route == .editor)
        #expect(plan.state.windows.map(\.id) == [windowID])
        #expect(plan.state.immersiveSpace?.id == "studio")

        let repeated = try RouterPlan<RouteFixture> {
            for route in [RouteFixture.home, .detail, .settings] {
                RouterPlanStep.action(.push(route))
            }
        }
        #expect(repeated.state.root == .stack(path: [.home, .detail, .settings]))
    }

    @Test("Plan builder validates the final whole-router state")
    func planBuilderValidation() {
        let duplicateID = UUID()

        #expect(throws: RouterStateValidationError.self) {
            _ = try RouterPlan<RouteFixture> {
                RouterPlanStep.windows([
                    .init(id: duplicateID, route: .home),
                    .init(id: duplicateID, route: .detail),
                ])
            }
        }
    }
}

@Suite("Deep-link value and matcher contracts")
struct DeepLinkValueContractTests {
    private enum Match: String, Sendable {
        case direct
        case array
        case optional
        case either
        case repeated
        case fallback
    }

    private struct Token: DeepLinkParameterValue, Equatable {
        let rawValue: String

        static func parseDeepLinkParameter(_ value: String) -> Self? {
            value.hasPrefix("token-") ? .init(rawValue: value) : nil
        }

        var deepLinkParameterString: String { rawValue }
    }

    @Test("Standard parameter values parse valid input and reject overflow")
    func standardParameterValues() {
        #expect(String.parseDeepLinkParameter("value") == "value")
        #expect(Int.parseDeepLinkParameter("-42") == -42)
        #expect(Int8.parseDeepLinkParameter("127") == 127)
        #expect(Int8.parseDeepLinkParameter("128") == nil)
        #expect(Int16.parseDeepLinkParameter("32767") == 32767)
        #expect(Int32.parseDeepLinkParameter("2147483647") == 2_147_483_647)
        #expect(Int64.parseDeepLinkParameter("-9223372036854775808") == Int64.min)
        #expect(UInt.parseDeepLinkParameter("42") == 42)
        #expect(UInt8.parseDeepLinkParameter("255") == 255)
        #expect(UInt8.parseDeepLinkParameter("-1") == nil)
        #expect(UInt16.parseDeepLinkParameter("65535") == 65_535)
        #expect(UInt32.parseDeepLinkParameter("4294967295") == 4_294_967_295)
        #expect(UInt64.parseDeepLinkParameter("18446744073709551615") == UInt64.max)
        #expect(Double.parseDeepLinkParameter("3.25") == 3.25)
        #expect(Float.parseDeepLinkParameter("1.5") == 1.5)
        #expect(Bool.parseDeepLinkParameter("true") == true)
        #expect(Bool.parseDeepLinkParameter("yes") == nil)

        let uuid = UUID()
        #expect(UUID.parseDeepLinkParameter(uuid.uuidString) == uuid)
        #expect(UUID.parseDeepLinkParameter("not-a-uuid") == nil)
        #expect(42.deepLinkParameterString == "42")
        #expect(Token.parseDeepLinkParameter("token-42") == Token(rawValue: "token-42"))
        #expect(Token.parseDeepLinkParameter("42") == nil)
        #expect(Token(rawValue: "token-42").deepLinkParameterString == "token-42")
    }

    @Test("Captured path and repeated query values expose typed accessors")
    func typedCapturedValues() throws {
        struct Capture: Sendable, Equatable {
            let first: Int?
            let missing: String?
            let all: [Int]
            let raw: [String]
        }
        let matcher = DeepLinkMatcher<Capture>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/items/:id") { parameters in
                Capture(
                    first: parameters.firstValue(forName: "id", as: Int.self),
                    missing: parameters.firstValue(forName: "missing"),
                    all: parameters.values(forName: "page", as: Int.self),
                    raw: parameters.values(forName: "page")
                )
            }
        }
        let url = try #require(URL(string: "https://app/items/42?page=1&page=nope&page=3"))

        #expect(matcher.match(url) == Capture(
            first: 42,
            missing: nil,
            all: [1, 3],
            raw: ["1", "nope", "3"]
        ))
    }

    @Test("Mapping result builder preserves declaration order across every branch shape")
    func mappingBuilderBranches() {
        let includeOptional = true
        let chooseFirst = false
        let repeated = [1, 2]
        let matcher = DeepLinkMatcher<Match>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/direct") { _ in .direct }
            [DeepLinkMapping("/array") { _ in .array }]
            if includeOptional {
                DeepLinkMapping("/optional") { _ in .optional }
            }
            if chooseFirst {
                DeepLinkMapping("/first") { _ in .direct }
            } else {
                DeepLinkMapping("/either") { _ in .either }
            }
            for value in repeated {
                DeepLinkMapping("/repeated/\(value)") { _ in .repeated }
            }
            DeepLinkMapping("/:value") { _ in nil }
            DeepLinkMapping("/:fallback") { _ in .fallback }
        }

        #expect(matcher.match("https://app/direct") == .direct)
        #expect(matcher.match("https://app/array") == .array)
        #expect(matcher.match("https://app/optional") == .optional)
        #expect(matcher.match("https://app/either") == .either)
        #expect(matcher.match("https://app/repeated/2") == .repeated)
        #expect(matcher.match("https://app/unknown") == .fallback)
        #expect(matcher.match("https://[") == nil)
    }

    // `diagnostics` is computed on demand so that building a matcher — which
    // `@Router` does inside every generated `resolveDeepLink` call — does not
    // pay the quadratic pattern-pair comparison. `.disabled` must keep
    // suppressing emission only, never availability, and repeated reads must
    // stay stable.
    @Test("Disabled diagnostics remain readable and stable across accesses")
    func disabledDiagnosticsRemainReadable() {
        let matcher = DeepLinkMatcher<Match>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/home") { _ in .direct }
            DeepLinkMapping("/home") { _ in .direct }
        }

        let first = matcher.diagnostics
        #expect(first.contains {
            if case .duplicatePattern = $0 { true } else { false }
        })
        #expect(matcher.diagnostics == first)

        let quiet = DeepLinkMatcher<Match>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/home") { _ in .direct }
            DeepLinkMapping("/settings") { _ in .direct }
        }
        #expect(quiet.diagnostics.isEmpty)
    }

    @Test("Strict diagnostics cover every structural authoring failure")
    func strictDiagnostics() throws {
        let matcher = DeepLinkMatcher<Match>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/api/*/users") { _ in .direct }
            DeepLinkMapping("/home") { _ in .direct }
            DeepLinkMapping("/home") { _ in .direct }
            DeepLinkMapping("/files/*") { _ in .direct }
            DeepLinkMapping("/files/public") { _ in .direct }
            DeepLinkMapping("/:slug") { _ in .direct }
            DeepLinkMapping("/settings") { _ in .direct }
            DeepLinkMapping("/:not-valid") { _ in .direct }
        }

        #expect(matcher.diagnostics.contains {
            if case .nonTerminalWildcard = $0 { true } else { false }
        })
        #expect(matcher.diagnostics.contains {
            if case .duplicatePattern = $0 { true } else { false }
        })
        #expect(matcher.diagnostics.contains {
            if case .wildcardShadowing = $0 { true } else { false }
        })
        #expect(matcher.diagnostics.contains {
            if case .parameterShadowing = $0 { true } else { false }
        })
        #expect(matcher.diagnostics.contains {
            if case .invalidParameterName = $0 { true } else { false }
        })
        #expect(matcher.diagnostics.allSatisfy { !$0.message.isEmpty })

        #expect(throws: DeepLinkMatcherStrictError.self) {
            _ = try DeepLinkMatcher<Match>(strict: ()) {
                DeepLinkMapping("/duplicate") { _ in .direct }
                DeepLinkMapping("/duplicate") { _ in .direct }
            }
        }

        let strict = try DeepLinkMatcher<Match>(strict: ()) {
            DeepLinkMapping("/valid/:id") { _ in .direct }
        }
        #expect(strict.diagnostics.isEmpty)
        #expect(strict.match("https://app/valid/42") == .direct)
    }

    @Test("Input limits fail closed with actionable descriptions")
    func inputLimits() throws {
        let limits = DeepLinkInputLimits(
            maxURLLength: 24,
            maxPathSegments: 2,
            maxQueryItems: 2
        )
        let tooLong = try #require(URL(string: "https://app.example.com/this-is-too-long"))
        let tooManySegments = try #require(URL(string: "app://host/a/b/c"))
        let tooManyQueries = try #require(URL(string: "app://host/a?q=1&q=2&q=3"))

        guard case .urlLengthExceeded(let actual, 24) = limits.violation(for: tooLong) else {
            Issue.record("Expected URL length violation")
            return
        }
        #expect(actual > 24)
        guard case .pathSegmentCountExceeded(3, 2) = limits.violation(for: tooManySegments) else {
            Issue.record("Expected path-segment violation")
            return
        }
        guard case .queryItemCountExceeded(3, 2) = limits.violation(for: tooManyQueries) else {
            Issue.record("Expected query-item violation")
            return
        }

        let descriptions = [
            DeepLinkInputLimitViolation.urlLengthExceeded(actual: 30, max: 24),
            .pathSegmentCountExceeded(actual: 3, max: 2),
            .queryItemCountExceeded(actual: 3, max: 2),
        ].map(\.localizedDescription)
        #expect(descriptions.allSatisfy { !$0.isEmpty })
        #expect(DeepLinkInputLimits.unlimited.violation(for: tooLong) == nil)
    }
}

@Suite("Deep-link pipeline admission contracts")
struct DeepLinkPipelineAdmissionContractTests {
    private enum RouteFixture: String, Route {
        case home
        case protected
    }

    @Test("Route matchers use custom planners and authenticated sessions pass through")
    func routePlannerAndAuthenticatedPassThrough() async throws {
        let matcher = DeepLinkMatcher<RouteFixture>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/protected") { _ in .protected }
        }
        let pipeline = RouterLinkPipeline(
            originPolicy: .allowlisted(schemes: ["app"], hosts: ["host"]),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .protected },
                isAuthenticated: { true }
            ),
            plan: { route in
                RouterPlan(state: .rootStack(path: [.home, route]))
            }
        )
        let url = try #require(URL(string: "app://host/protected"))

        guard case .plan(let plan) = await pipeline.decide(for: url) else {
            Issue.record("Expected authenticated plan")
            return
        }
        #expect(plan.state.root == .stack(path: [.home, .protected]))
    }

    @Test("Admission distinguishes host rejection, resource limits, and unhandled URLs")
    func admissionFailures() async throws {
        let matcher = DeepLinkMatcher<RouteFixture>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            DeepLinkMapping("/home") { _ in .home }
        }
        let pipeline = RouterLinkPipeline(
            originPolicy: .allowlisted(schemes: ["app"], hosts: ["host"]),
            matcher: matcher,
            inputLimits: .init(maxURLLength: 100, maxPathSegments: 1, maxQueryItems: 1)
        )

        let wrongHost = try #require(URL(string: "app://other/home"))
        let tooManySegments = try #require(URL(string: "app://host/a/b"))
        let unhandled = try #require(URL(string: "app://host/other"))

        #expect(await pipeline.decide(for: wrongHost) == .rejected(
            reason: .hostNotAllowed(actualHost: "other")
        ))
        #expect(await pipeline.decide(for: tooManySegments) == .rejected(
            reason: .inputLimitExceeded(
                .pathSegmentCountExceeded(actual: 2, max: 1)
            )
        ))
        #expect(await pipeline.decide(for: unhandled) == .unhandled(url: unhandled))

        let descriptions = [
            DeepLinkRejectionReason.schemeNotAllowed(actualScheme: nil),
            .hostNotAllowed(actualHost: nil),
            .inputLimitExceeded(.queryItemCountExceeded(actual: 2, max: 1)),
        ].map(\.localizedDescription)
        #expect(descriptions.allSatisfy { !$0.isEmpty })
    }
}
