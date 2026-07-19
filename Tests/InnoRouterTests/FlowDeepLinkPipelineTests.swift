// MARK: - FlowDeepLinkPipelineTests.swift
// InnoRouterTests - FlowDeepLinkPipeline decide(for:)
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouter
import InnoRouterDeepLink

private enum PipelineRoute: Route {
    case home
    case detail(id: String)
    case privacyPolicy
    case requiresAuth
}

@Suite("FlowDeepLinkPipeline Tests")
struct FlowDeepLinkPipelineTests {

    private func makeMatcher() -> DeepLinkMatcher<FlowPlan<PipelineRoute>> {
        DeepLinkMatcher<FlowPlan<PipelineRoute>> {
            DeepLinkMapping("/home") { _ in
                FlowPlan(steps: [.push(.home)])
            }
            DeepLinkMapping("/home/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
            }
            DeepLinkMapping("/onboarding/privacy") { _ in
                FlowPlan(steps: [.sheet(.privacyPolicy)])
            }
            DeepLinkMapping("/secure") { _ in
                FlowPlan(steps: [.push(.requiresAuth)])
            }
        }
    }

    @Test(".rejected when scheme is not allowed")
    func schemeRejection() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            originPolicy: .allowlisted(schemes: ["myapp"], hosts: ["app"]),
            matcher: makeMatcher()
        )
        let decision = pipeline.decide(for: URL(string: "other://app/home")!)
        if case .rejected(.schemeNotAllowed(let actual)) = decision {
            #expect(actual == "other")
        } else {
            Issue.record("Expected .rejected(.schemeNotAllowed), got \(decision)")
        }
    }

    @Test(".rejected when host is not allowed")
    func hostRejection() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            originPolicy: .allowlisted(schemes: ["myapp"], hosts: ["app"]),
            matcher: makeMatcher()
        )
        let decision = pipeline.decide(for: URL(string: "myapp://other/home")!)
        if case .rejected(.hostNotAllowed) = decision {
            // expected
        } else {
            Issue.record("Expected .rejected(.hostNotAllowed), got \(decision)")
        }
    }

    @Test(".rejected when input limits are exceeded")
    func inputLimitRejection() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            inputLimits: DeepLinkInputLimits(maxPathSegments: 1)
        )
        let decision = pipeline.decide(for: URL(string: "myapp://app/home/detail/42")!)
        if case .rejected(.inputLimitExceeded(.pathSegmentCountExceeded(let actual, let max))) = decision {
            #expect(actual == 3)
            #expect(max == 1)
        } else {
            Issue.record("Expected .rejected(.inputLimitExceeded), got \(decision)")
        }
    }

    @Test(".rejected when matcher input limits are exceeded")
    func matcherInputLimitRejection() {
        let matcher = DeepLinkMatcher<FlowPlan<PipelineRoute>>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
            )
        ) {
            DeepLinkMapping("/home/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
            }
        }
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: matcher,
            inputLimits: .unlimited
        )

        let decision = pipeline.decide(for: URL(string: "myapp://app/home/detail/42?a=1&b=2")!)
        if case .rejected(.inputLimitExceeded(.queryItemCountExceeded(let actual, let max))) = decision {
            #expect(actual == 2)
            #expect(max == 1)
        } else {
            Issue.record("Expected matcher .inputLimitExceeded rejection, got \(decision)")
        }
    }

    @Test(".unhandled when no mapping matches")
    func unmatchedURL() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher()
        )
        let url = URL(string: "myapp://app/nowhere")!
        let decision = pipeline.decide(for: url)
        if case .unhandled(let unhandledURL) = decision {
            #expect(unhandledURL == url)
        } else {
            Issue.record("Expected .unhandled, got \(decision)")
        }
    }

    @Test("Happy path returns .flowPlan with the matched plan")
    func happyPath() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher()
        )
        let decision = pipeline.decide(for: URL(string: "myapp://app/home/detail/42")!)
        if case .flowPlan(let plan) = decision {
            #expect(plan == FlowPlan(steps: [.push(.home), .push(.detail(id: "42"))]))
        } else {
            Issue.record("Expected .flowPlan, got \(decision)")
        }
    }

    @Test("Modal-terminal URL produces a .flowPlan with a sheet tail")
    func modalTerminal() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher()
        )
        let decision = pipeline.decide(for: URL(string: "myapp://app/onboarding/privacy")!)
        if case .flowPlan(let plan) = decision {
            #expect(plan == FlowPlan(steps: [.sheet(.privacyPolicy)]))
        } else {
            Issue.record("Expected .flowPlan, got \(decision)")
        }
    }

    @Test("Authentication .defer returns .pending with gatedRoute and plan")
    func authDefers() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .requiresAuth = route { return true }
                    return false
                },
                isAuthenticated: { false }
            )
        )
        let decision = pipeline.decide(for: URL(string: "myapp://app/secure")!)
        if case .pending(let pending) = decision {
            if case .requiresAuth = pending.gatedRoute {
                // expected
            } else {
                Issue.record("Expected gatedRoute == .requiresAuth, got \(pending.gatedRoute)")
            }
            #expect(pending.plan == FlowPlan(steps: [.push(.requiresAuth)]))
        } else {
            Issue.record("Expected .pending, got \(decision)")
        }
    }

    @Test("Authentication .required passes through when already authenticated")
    func authPasses() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .requiresAuth = route { return true }
                    return false
                },
                isAuthenticated: { true }
            )
        )
        let decision = pipeline.decide(for: URL(string: "myapp://app/secure")!)
        if case .flowPlan(let plan) = decision {
            #expect(plan == FlowPlan(steps: [.push(.requiresAuth)]))
        } else {
            Issue.record("Expected .flowPlan, got \(decision)")
        }
    }

    @Test("Authentication policy scans the whole plan and defers on the first protected route")
    func authScansWholePlan() {
        let pipeline = FlowDeepLinkPipeline<PipelineRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .detail = route { return true }
                    return false
                },
                isAuthenticated: { false }
            )
        )
        let decision = pipeline.decide(for: URL(string: "myapp://app/home/detail/42")!)
        if case .pending(let pending) = decision {
            #expect(pending.gatedRoute == .detail(id: "42"))
            #expect(pending.plan == FlowPlan(steps: [.push(.home), .push(.detail(id: "42"))]))
        } else {
            Issue.record("Expected .pending for protected tail route, got \(decision)")
        }
    }
}
