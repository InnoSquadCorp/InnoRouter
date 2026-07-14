// MARK: - FlowDeepLinkEffectHandlerTests.swift
// InnoRouterTests - FlowDeepLinkEffectHandler end-to-end
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI
import InnoRouterDeepLink
import InnoRouterDeepLinkEffects

private enum EffectRoute: Route {
    case home
    case detail(id: String)
    case comments(id: String)
    case privacyPolicy
    case secure
}

@MainActor
private func blockEverythingNavigationMiddleware() -> AnyNavigationMiddleware<EffectRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in
        .cancel(.middleware(debugName: nil, command: command))
    })
}

@MainActor
private func makePipeline() -> FlowDeepLinkPipeline<EffectRoute> {
    let matcher = DeepLinkMatcher<FlowPlan<EffectRoute>> {
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
            FlowPlan(steps: [.push(.secure)])
        }
    }
    return FlowDeepLinkPipeline<EffectRoute>(
        allowedSchemes: ["myapp"],
        matcher: matcher
    )
}

@Suite("FlowDeepLinkEffectHandler Tests")
struct FlowDeepLinkEffectHandlerTests {
    enum AuthorizationProbeError: Error, Equatable {
        case failed
    }

    @Test("Happy path: handle(url) applies the plan and returns .executed with the resulting path")
    @MainActor
    func happyPathApplies() {
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )

        let result = handler.handle(URL(string: "myapp://app/home/detail/42")!)

        if case .executed(let plan, let path) = result {
            #expect(plan == FlowPlan(steps: [.push(.home), .push(.detail(id: "42"))]))
            #expect(path == [.push(.home), .push(.detail(id: "42"))])
        } else {
            Issue.record("Expected .executed, got \(result)")
        }

        #expect(store.path == [.push(.home), .push(.detail(id: "42"))])
        #expect(store.navigationStore.state.path == [.home, .detail(id: "42")])
        #expect(store.modalStore.currentPresentation == nil)
    }

    @Test("Modal-terminal URL lands as .sheet on the modal store")
    @MainActor
    func modalTerminalLandsAsSheet() {
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )

        let result = handler.handle(URL(string: "myapp://app/onboarding/privacy")!)

        if case .executed = result {
            // expected
        } else {
            Issue.record("Expected .executed, got \(result)")
        }

        #expect(store.path == [.sheet(.privacyPolicy)])
        #expect(store.modalStore.currentPresentation?.route == .privacyPolicy)
    }

    @Test("handle(_:) returns .invalidURL for empty string input")
    @MainActor
    func invalidURLInput() {
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )
        // `URL(string:)` is permissive and accepts most strings —
        // the empty string is one of the few inputs that yields
        // `nil`, which is the only path to `.invalidURL`.
        let result = handler.handle("")
        if case .invalidURL(let input) = result {
            #expect(input == "")
        } else {
            Issue.record("Expected .invalidURL, got \(result)")
        }
    }

    @Test("Unmatched URL returns .unhandled and leaves the store untouched")
    @MainActor
    func unmatchedURL() {
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )
        let result = handler.handle(URL(string: "myapp://app/nowhere")!)
        if case .unhandled = result {
            // expected
        } else {
            Issue.record("Expected .unhandled, got \(result)")
        }
        #expect(store.path.isEmpty)
    }

    @Test("Authentication deferral: .pending is stored, resumePendingDeepLink replays on reauth")
    @MainActor
    func authenticationDeferralAndReplay() {
        let isAuthed = Mutex<Bool>(false)
        let matcher = DeepLinkMatcher<FlowPlan<EffectRoute>> {
            DeepLinkMapping("/secure") { _ in
                FlowPlan(steps: [.push(.secure)])
            }
        }
        let pipeline = FlowDeepLinkPipeline<EffectRoute>(
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
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: store
        )

        // First attempt: not authenticated → .pending.
        let firstResult = handler.handle(URL(string: "myapp://app/secure")!)
        if case .pending(let pending) = firstResult {
            #expect(pending.gatedRoute == .secure)
        } else {
            Issue.record("Expected .pending, got \(firstResult)")
        }
        #expect(store.path.isEmpty)
        #expect(handler.hasPendingDeepLink)

        // Simulate sign-in.
        isAuthed.withLock { $0 = true }

        // Resume: now authenticated → .executed.
        let secondResult = handler.resumePendingDeepLink()
        if case .executed(let plan, _) = secondResult {
            #expect(plan == FlowPlan(steps: [.push(.secure)]))
        } else {
            Issue.record("Expected .executed on resume, got \(secondResult)")
        }
        #expect(store.path == [.push(.secure)])
        #expect(!handler.hasPendingDeepLink)
    }

    @Test("resumePendingDeepLink with no queued link returns .noPendingDeepLink")
    @MainActor
    func resumeWithoutPending() {
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )
        let result = handler.resumePendingDeepLink()
        if case .noPendingDeepLink = result {
            // expected
        } else {
            Issue.record("Expected .noPendingDeepLink, got \(result)")
        }
    }

    @Test("Throwing resumePendingDeepLinkIfAllowed propagates auth probe failures")
    @MainActor
    func throwingResumePendingDeepLinkIfAllowedPropagatesFailure() async {
        let pipeline = FlowDeepLinkPipeline<EffectRoute>(
            allowedSchemes: ["myapp"],
            matcher: makePipeline().matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            )
        )
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: store
        )

        _ = handler.handle(URL(string: "myapp://app/secure")!)

        do {
            _ = try await handler.resumePendingDeepLinkIfAllowed { _ async throws -> Bool in
                throw AuthorizationProbeError.failed
            }
            Issue.record("Expected authorization probe failure")
        } catch AuthorizationProbeError.failed {
            #expect(handler.hasPendingDeepLink)
            #expect(store.path.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("clearPendingDeepLink drops a queued link without applying it")
    @MainActor
    func clearPending() {
        let pipeline = FlowDeepLinkPipeline<EffectRoute>(
            allowedSchemes: ["myapp"],
            matcher: makePipeline().matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            )
        )
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: store
        )
        _ = handler.handle(URL(string: "myapp://app/secure")!)
        #expect(handler.hasPendingDeepLink)

        handler.clearPendingDeepLink()
        #expect(!handler.hasPendingDeepLink)
    }

    @Test("End-to-end: flowStore.events emits .pathChanged after applying a multi-step URL")
    @MainActor
    func endToEndEventsStream() async {
        let store = FlowStore<EffectRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )
        var iterator = store.events.makeAsyncIterator()

        _ = handler.handle(URL(string: "myapp://app/home/detail/42")!)

        var sawPathChanged = false
        for _ in 0..<10 {
            let event = await iterator.next()
            if case .pathChanged(_, let new) = event,
               new == [.push(.home), .push(.detail(id: "42"))] {
                sawPathChanged = true
                break
            }
        }
        #expect(sawPathChanged)
    }

    @Test("Middleware cancellation on the FlowStore rolls back the plan application")
    @MainActor
    func middlewareCancellationRollsBack() {
        let store = FlowStore<EffectRoute>(
            configuration: FlowStoreConfiguration(
                navigation: NavigationStoreConfiguration(
                    middlewares: [.init(middleware: blockEverythingNavigationMiddleware(), debugName: "blocker")]
                )
            )
        )
        let handler = FlowDeepLinkEffectHandler(
            pipeline: makePipeline(),
            applier: store
        )

        let result = handler.handle(URL(string: "myapp://app/home/detail/42")!)

        if case .applicationRejected(let plan, let path) = result {
            #expect(plan == FlowPlan(steps: [.push(.home), .push(.detail(id: "42"))]))
            #expect(path.isEmpty)
        } else {
            Issue.record("Expected .applicationRejected, got \(result)")
        }

        // The pipeline still produces .flowPlan and applier.apply is
        // called, but FlowStore's middleware cancels the underlying
        // reset. The store's path therefore stays empty.
        #expect(store.path.isEmpty)
    }

    @Test("resumePendingDeepLink returns .applicationRejected when apply is rejected after auth succeeds")
    @MainActor
    func resumeRejectedAfterAuthOpens() {
        let isAuthed = Mutex<Bool>(false)
        let matcher = DeepLinkMatcher<FlowPlan<EffectRoute>> {
            DeepLinkMapping("/secure") { _ in
                FlowPlan(steps: [.push(.secure)])
            }
        }
        let pipeline = FlowDeepLinkPipeline<EffectRoute>(
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
        let store = FlowStore<EffectRoute>(
            configuration: FlowStoreConfiguration(
                navigation: NavigationStoreConfiguration(
                    middlewares: [.init(middleware: blockEverythingNavigationMiddleware(), debugName: "blocker")]
                )
            )
        )
        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: store
        )

        _ = handler.handle(URL(string: "myapp://app/secure")!)
        #expect(handler.hasPendingDeepLink)

        isAuthed.withLock { $0 = true }

        let result = handler.resumePendingDeepLink()
        if case .applicationRejected(let plan, let path) = result {
            #expect(plan == FlowPlan(steps: [.push(.secure)]))
            #expect(path.isEmpty)
        } else {
            Issue.record("Expected .applicationRejected on resume, got \(result)")
        }
        #expect(!handler.hasPendingDeepLink)
        #expect(store.path.isEmpty)
    }
}
