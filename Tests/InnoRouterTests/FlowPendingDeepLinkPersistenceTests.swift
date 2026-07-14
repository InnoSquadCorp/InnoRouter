// MARK: - FlowPendingDeepLinkPersistenceTests.swift
// InnoRouterTests - cross-launch pending deep link replay
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterDeepLink
import InnoRouterDeepLinkEffects

private enum PendingRoute: String, Route, Codable {
    case home
    case secure
}

@Suite("FlowPendingDeepLinkPersistence Tests")
struct FlowPendingDeepLinkPersistenceTests {

    @Test("FlowPendingDeepLink round-trips through the persistence helper")
    func roundTrip() throws {
        let persistence = FlowPendingDeepLinkPersistence<PendingRoute>()
        let original = FlowPendingDeepLink<PendingRoute>(
            url: URL(string: "myapp://app/secure")!,
            gatedRoute: .secure,
            plan: FlowPlan(steps: [.push(.secure)])
        )

        let data = try persistence.encode(original)
        let restored = try persistence.decode(data)

        #expect(restored == original)
    }

    @Test("Malformed JSON surfaces as DecodingError")
    func malformedInput() {
        let persistence = FlowPendingDeepLinkPersistence<PendingRoute>()
        #expect(throws: DecodingError.self) {
            _ = try persistence.decode(Data("garbage".utf8))
        }
    }

    @Test("End-to-end: persist → restore into fresh handler → replay")
    @MainActor
    func endToEndRelaunch() throws {
        let isAuthed = Mutex<Bool>(false)

        // Build a pipeline that gates .secure behind authentication.
        let matcher = DeepLinkMatcher<FlowPlan<PendingRoute>> {
            DeepLinkMapping("/secure") { _ in
                FlowPlan(steps: [.push(.secure)])
            }
        }
        let pipeline = FlowDeepLinkPipeline<PendingRoute>(
            allowedSchemes: ["myapp"],
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    if case .secure = route { return true }
                    return false
                },
                isAuthenticated: { isAuthed.withLock { $0 } }
            )
        )

        // First "launch" — produces the pending link.
        let persistence = FlowPendingDeepLinkPersistence<PendingRoute>()
        let firstStore = FlowStore<PendingRoute>()
        let firstHandler = FlowDeepLinkEffectHandler<PendingRoute>(
            pipeline: pipeline,
            applier: firstStore
        )
        let decision = firstHandler.handle(URL(string: "myapp://app/secure")!)
        guard case .pending(let pending) = decision else {
            Issue.record("Expected .pending from first launch, got \(decision)")
            return
        }
        let data = try persistence.encode(pending)

        // Second "launch" — fresh handler, decode the pending, then
        // simulate authentication and replay.
        let secondStore = FlowStore<PendingRoute>()
        let secondHandler = FlowDeepLinkEffectHandler<PendingRoute>(
            pipeline: pipeline,
            applier: secondStore
        )
        let restored = try persistence.decode(data)
        secondHandler.restore(pending: restored)
        #expect(secondHandler.hasPendingDeepLink)

        isAuthed.withLock { $0 = true }
        let replay = secondHandler.resumePendingDeepLink()
        if case .executed(let plan, _) = replay {
            #expect(plan.steps == [.push(.secure)])
        } else {
            Issue.record("Expected .executed on replay, got \(replay)")
        }
        #expect(secondStore.path == [.push(.secure)])
        #expect(!secondHandler.hasPendingDeepLink)
    }
}
