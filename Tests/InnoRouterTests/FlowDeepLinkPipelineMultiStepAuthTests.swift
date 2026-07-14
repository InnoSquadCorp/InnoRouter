// MARK: - FlowDeepLinkPipelineMultiStepAuthTests.swift
// InnoRouterTests - all-or-nothing semantics of multi-step plans + auth gates
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouter
import InnoRouterDeepLink

private enum MultiAuthRoute: Route {
    case home
    case settings
    case profile
    case dangerous
}

@Suite("FlowDeepLinkPipeline multi-step authentication semantics")
struct FlowDeepLinkPipelineMultiStepAuthTests {

    // The matcher emits multi-step plans where individual steps may
    // independently be flagged protected. The pipeline is expected to
    // defer the entire plan when any step is protected — not just the
    // gated suffix.
    private func makeMatcher() -> DeepLinkMatcher<FlowPlan<MultiAuthRoute>> {
        DeepLinkMatcher<FlowPlan<MultiAuthRoute>> {
            DeepLinkMapping("/onboarding/profile") { _ in
                FlowPlan(steps: [.push(.home), .push(.profile)])
            }
            DeepLinkMapping("/admin/dangerous") { _ in
                FlowPlan(steps: [
                    .push(.home),
                    .push(.settings),
                    .push(.dangerous),
                ])
            }
        }
    }

    @Test("Protected tail step gates the entire plan; full plan is preserved")
    func tailGatedDefersWholePlan() {
        let pipeline = FlowDeepLinkPipeline<MultiAuthRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .profile = route { return true }
                    return false
                },
                isAuthenticated: { false }
            )
        )

        let decision = pipeline.decide(for: URL(string: "myapp://app/onboarding/profile")!)

        guard case .pending(let pending) = decision else {
            Issue.record("Expected .pending, got \(decision)")
            return
        }
        #expect(pending.gatedRoute == .profile)
        // The full original plan must be preserved — the unprotected
        // .home step is NOT applied separately.
        #expect(pending.plan == FlowPlan(steps: [.push(.home), .push(.profile)]))
    }

    @Test("Protected middle step gates the plan and reports itself as the gatedRoute")
    func middleGatedReportsFirstProtectedRoute() {
        let pipeline = FlowDeepLinkPipeline<MultiAuthRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    // .settings is in the middle; .dangerous is the tail.
                    if case .settings = route { return true }
                    if case .dangerous = route { return true }
                    return false
                },
                isAuthenticated: { false }
            )
        )

        let decision = pipeline.decide(for: URL(string: "myapp://app/admin/dangerous")!)

        guard case .pending(let pending) = decision else {
            Issue.record("Expected .pending, got \(decision)")
            return
        }
        // The pipeline returns the FIRST protected route in plan order,
        // not the deepest one.
        #expect(pending.gatedRoute == .settings)
        #expect(pending.plan == FlowPlan(steps: [
            .push(.home),
            .push(.settings),
            .push(.dangerous),
        ]))
    }

    @Test("Plan passes through cleanly when all steps are unprotected")
    func unprotectedMultiStepPasses() {
        let pipeline = FlowDeepLinkPipeline<MultiAuthRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in false },
                isAuthenticated: { false }
            )
        )

        let decision = pipeline.decide(for: URL(string: "myapp://app/onboarding/profile")!)

        guard case .flowPlan(let plan) = decision else {
            Issue.record("Expected .flowPlan, got \(decision)")
            return
        }
        #expect(plan == FlowPlan(steps: [.push(.home), .push(.profile)]))
    }

    @Test("Authenticated session bypasses protection and returns the full plan")
    func authenticatedBypassesProtection() {
        let pipeline = FlowDeepLinkPipeline<MultiAuthRoute>(
            allowedSchemes: ["myapp"],
            matcher: makeMatcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .profile = route { return true }
                    return false
                },
                isAuthenticated: { true }
            )
        )

        let decision = pipeline.decide(for: URL(string: "myapp://app/onboarding/profile")!)

        guard case .flowPlan(let plan) = decision else {
            Issue.record("Expected .flowPlan, got \(decision)")
            return
        }
        #expect(plan == FlowPlan(steps: [.push(.home), .push(.profile)]))
    }
}
