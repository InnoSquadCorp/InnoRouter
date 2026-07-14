// MARK: - FlowDeepLinkAsyncAuthTests.swift
// InnoRouterTests - async authentication-flow scenarios
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterDeepLink

private enum AsyncAuthRoute: Route {
    case home
    case profile
}

@Suite("FlowDeepLinkPipeline async authentication scenarios")
struct FlowDeepLinkAsyncAuthTests {

    // MARK: - Token-refresh defers then replays

    @Test("Authenticated state flip between decide() calls swaps pending into plan")
    @MainActor
    func tokenRefresh_replaysPendingDeepLink() {
        // The `isAuthenticated` closure is captured by the pipeline,
        // so flipping the backing storage between two `decide(for:)`
        // calls simulates an async token-refresh round trip without
        // requiring real concurrency primitives in the test.
        let isAuthenticated = AuthLatch(initial: false)

        let pipeline = FlowDeepLinkPipeline<AsyncAuthRoute>(
            allowedSchemes: ["app"],
            allowedHosts: ["onboarding"],
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/profile") { _ in
                    FlowPlan(steps: [.push(.home), .push(.profile)])
                }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in route == .profile },
                isAuthenticated: { isAuthenticated.value }
            )
        )

        let url = URL(string: "app://onboarding/profile")!

        // First call: token refresh in flight, request pends.
        let pending = pipeline.decide(for: url)
        guard case .pending(let pendingLink) = pending else {
            Issue.record("expected pending, got \(pending)")
            return
        }
        #expect(pendingLink.url == url)

        // Token refresh completes — auth flips to true.
        isAuthenticated.value = true

        // Second call resolves into a concrete plan with the same
        // steps.
        let resolved = pipeline.decide(for: url)
        guard case .flowPlan(let plan) = resolved else {
            Issue.record("expected plan after auth flip, got \(resolved)")
            return
        }
        #expect(plan.steps.count == 2)
    }

    // MARK: - Auth check flapping does not corrupt the matcher

    @Test("Repeated decide() calls under flapping auth keep producing consistent outcomes")
    @MainActor
    func flappingAuth_consistentOutcomes() {
        let isAuthenticated = AuthLatch(initial: false)
        let pipeline = FlowDeepLinkPipeline<AsyncAuthRoute>(
            allowedSchemes: ["app"],
            allowedHosts: ["onboarding"],
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/profile") { _ in
                    FlowPlan(steps: [.push(.profile)])
                }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { isAuthenticated.value }
            )
        )

        let url = URL(string: "app://onboarding/profile")!

        for cycle in 0..<10 {
            isAuthenticated.value = (cycle % 2 == 0)
            let outcome = pipeline.decide(for: url)
            switch (cycle % 2, outcome) {
            case (0, .flowPlan):
                continue
            case (1, .pending):
                continue
            default:
                Issue.record("cycle=\(cycle) auth=\(isAuthenticated.value) got \(outcome)")
                return
            }
        }
    }
}

// Mutex-protected latch so the @Sendable `isAuthenticated`
// closure can read it from any executor while the test driver
// flips the value on @MainActor.
private final class AuthLatch: Sendable {
    private let storage: Mutex<Bool>
    init(initial: Bool) {
        self.storage = Mutex(initial)
    }
    var value: Bool {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
