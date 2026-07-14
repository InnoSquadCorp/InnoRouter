// MARK: - DeepLinkEffectHandlerTests.swift
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
@testable import InnoRouterSwiftUI

// MARK: - DeepLinkEffectHandler Tests

@Suite("DeepLinkEffectHandler Tests")
struct DeepLinkEffectHandlerTests {
    enum AuthorizationProbeError: Error, Equatable {
        case failed
    }

    struct MockDeepLinkEffect: DeepLinkEffect {
        var deepLinkURL: URL?

        static func deepLink(_ url: URL) -> MockDeepLinkEffect {
            MockDeepLinkEffect(deepLinkURL: url)
        }
    }

    @Test("Execute plan result is returned even when last command is not push")
    @MainActor
    func testPlanExecutionResult() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            plan: { _ in NavigationPlan(commands: [.replace([.home, .settings])]) }
        )

        let result = handler.handle(URL(string: "myapp://myapp.com/settings")!)

        guard case .executed(let plan, let batch) = result else {
            Issue.record("Expected executed result")
            return
        }
        #expect(plan.commands == [.replace([.home, .settings])])
        #expect(batch.results == [.success])
        #expect(batch.executedCommands == [.replace([.home, .settings])])
        #expect(store.state.path == [.home, .settings])
    }

    @Test("Preconfigured custom-resolver pipeline executes through the handler")
    @MainActor
    func testPreconfiguredPipelineInitializer() {
        let store = NavigationStore<TestRoute>()
        let pipeline = DeepLinkPipeline<TestRoute>(
            allowedSchemes: ["myapp"],
            customResolver: { _ in .settings },
            plan: { _ in NavigationPlan(commands: [.replace([.home, .settings])]) }
        )
        let handler = DeepLinkEffectHandler(
            pipeline: pipeline,
            navigator: AnyBatchNavigator(store)
        )

        let result = handler.handle(URL(string: "myapp://myapp.com/custom")!)

        guard case .executed(let plan, let batch) = result else {
            Issue.record("Expected executed result")
            return
        }
        #expect(plan.commands == [.replace([.home, .settings])])
        #expect(batch.results == [.success])
        #expect(store.state.path == [.home, .settings])
    }

    @Test("Restored pending deep link remains replayable")
    @MainActor
    func testRestorePendingDeepLink() {
        let store = NavigationStore<TestRoute>()
        let pipeline = DeepLinkPipeline<TestRoute>(customResolver: { _ in .settings })
        let handler = DeepLinkEffectHandler(
            pipeline: pipeline,
            navigator: AnyBatchNavigator(store)
        )
        let pending = PendingDeepLink(
            url: URL(string: "myapp://myapp.com/settings")!,
            route: TestRoute.settings,
            plan: NavigationPlan(commands: [.replace([.home, .settings])])
        )

        handler.restore(pending: pending)

        #expect(handler.pendingDeepLink == pending)
        guard case .executed(let plan, let batch) = handler.resumePendingDeepLink() else {
            Issue.record("Expected restored pending deep link to execute")
            return
        }
        #expect(plan == pending.plan)
        #expect(batch.results == [.success])
        #expect(handler.pendingDeepLink == nil)
        #expect(store.state.path == [.home, .settings])
    }

    @Test("Resume pending deep link replays preserved plan")
    @MainActor
    func testResumePendingDeepLink() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let authState = Mutex(false)
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { authState.withLock { $0 } }
            ),
            plan: { _ in NavigationPlan(commands: [.replace([.home, .settings])]) }
        )

        let pendingResult = handler.handle(URL(string: "myapp://myapp.com/settings")!)
        guard case .pending = pendingResult else {
            Issue.record("Expected pending result")
            return
        }
        #expect(handler.pendingDeepLink != nil)

        authState.withLock { $0 = true }
        let resumeResult = handler.resumePendingDeepLink()
        guard case .executed(let plan, let batch) = resumeResult else {
            Issue.record("Expected executed result after resume")
            return
        }
        #expect(plan.commands == [.replace([.home, .settings])])
        #expect(batch.results == [.success])
        #expect(store.state.path == [.home, .settings])
        #expect(handler.pendingDeepLink == nil)
    }

    @Test("Async deep-link guard keeps pending until authorized")
    @MainActor
    func testResumePendingDeepLinkIfAllowed() async {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let authState = Mutex(false)
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { authState.withLock { $0 } }
            ),
            plan: { _ in NavigationPlan(commands: [.replace([.home, .settings])]) }
        )

        let pending = handler.handle(URL(string: "myapp://myapp.com/settings")!)
        guard case .pending = pending else {
            Issue.record("Expected pending result")
            return
        }

        let denied = await handler.resumePendingDeepLinkIfAllowed { _ in false }
        #expect(denied == .pending(handler.pendingDeepLink!))
        #expect(handler.pendingDeepLink != nil)
        #expect(store.state.path.isEmpty)

        authState.withLock { $0 = true }
        let resumed = await handler.resumePendingDeepLinkIfAllowed { _ in true }
        guard case .executed(_, let batch) = resumed else {
            Issue.record("Expected executed result after authorization")
            return
        }
        #expect(batch.results == [.success])
        #expect(store.state.path == [.home, .settings])
        #expect(handler.pendingDeepLink == nil)
    }

    @Test("Async deep-link guard does not resume a stale pending deep link")
    @MainActor
    func testResumePendingDeepLinkIfAllowedUsesCurrentPendingIdentity() async {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
            DeepLinkMapping("/home") { _ in .home }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            ),
            plan: { route in NavigationPlan(commands: [.push(route)]) }
        )

        let firstPending = handler.handle(URL(string: "myapp://myapp.com/settings")!)
        guard case .pending = firstPending else {
            Issue.record("Expected pending result")
            return
        }

        let resumed = await handler.resumePendingDeepLinkIfAllowed { _ in
            _ = handler.handle(URL(string: "myapp://myapp.com/home")!)
            return true
        }

        #expect(resumed == .pending(handler.pendingDeepLink!))
        #expect(handler.pendingDeepLink?.route == .home)
        #expect(store.state.path.isEmpty)
    }

    @Test("Async deep-link guard preserves an equal pending replacement")
    @MainActor
    func testResumePendingDeepLinkIfAllowedDoesNotConsumeEqualReplacement() async {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let authState = Mutex(false)
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { authState.withLock { $0 } }
            ),
            plan: { route in NavigationPlan(commands: [.push(route)]) }
        )
        let url = URL(string: "myapp://myapp.com/settings")!

        guard case .pending(let original) = handler.handle(url) else {
            Issue.record("Expected pending result")
            return
        }

        let resumed = await handler.resumePendingDeepLinkIfAllowed { captured in
            #expect(handler.handle(url) == .pending(captured))
            authState.withLock { $0 = true }
            return true
        }

        #expect(resumed == .pending(original))
        #expect(handler.pendingDeepLink == original)
        #expect(store.state.path.isEmpty)

        guard case .executed = handler.resumePendingDeepLink() else {
            Issue.record("Expected the replacement to remain replayable")
            return
        }
        #expect(handler.pendingDeepLink == nil)
        #expect(store.state.path == [.settings])
    }

    @Test("Async deep-link guard returns the current pending deep link after denied stale authorization")
    @MainActor
    func testResumePendingDeepLinkIfAllowedDeniedUsesCurrentPendingIdentity() async {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
            DeepLinkMapping("/home") { _ in .home }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            ),
            plan: { route in NavigationPlan(commands: [.push(route)]) }
        )

        let firstPending = handler.handle(URL(string: "myapp://myapp.com/settings")!)
        guard case .pending = firstPending else {
            Issue.record("Expected pending result")
            return
        }

        let denied = await handler.resumePendingDeepLinkIfAllowed { _ in
            _ = handler.handle(URL(string: "myapp://myapp.com/home")!)
            return false
        }

        #expect(denied == .pending(handler.pendingDeepLink!))
        #expect(handler.pendingDeepLink?.route == .home)
        #expect(store.state.path.isEmpty)
    }

    @Test("Throwing async deep-link guard propagates auth probe failures")
    @MainActor
    func testThrowingResumePendingDeepLinkIfAllowedPropagatesFailure() async {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            ),
            plan: { route in NavigationPlan(commands: [.push(route)]) }
        )

        _ = handler.handle(URL(string: "myapp://myapp.com/settings")!)

        do {
            _ = try await handler.resumePendingDeepLinkIfAllowed { _ async throws -> Bool in
                throw AuthorizationProbeError.failed
            }
            Issue.record("Expected authorization probe failure")
        } catch AuthorizationProbeError.failed {
            #expect(handler.pendingDeepLink != nil)
            #expect(store.state.path.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Rejected decision preserves rejection reason")
    @MainActor
    func testRejectedReasonIsPreserved() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            allowedSchemes: ["myapp"]
        )

        let result = handler.handle(URL(string: "https://myapp.com/settings")!)
        guard case .rejected(let reason) = result else {
            Issue.record("Expected rejected result")
            return
        }
        #expect(reason == .schemeNotAllowed(actualScheme: "https"))
    }

    @Test("Matcher input-limit rejection prevents navigation execution")
    @MainActor
    func testMatcherInputLimitRejectionPreventsExecution() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute>(
            configuration: .init(
                diagnosticsMode: .disabled,
                inputLimits: DeepLinkInputLimits(maxQueryItems: 1)
            )
        ) {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            inputLimits: .unlimited
        )

        let result = handler.handle(
            URL(string: "myapp://myapp.com/settings?a=1&b=2")!
        )

        #expect(
            result == .rejected(
                reason: .inputLimitExceeded(
                    .queryItemCountExceeded(actual: 2, max: 1)
                )
            )
        )
        #expect(store.state.path.isEmpty)
    }

    @Test("Plan validation rejection prevents execution")
    @MainActor
    func testPlanValidationRejectionPreventsExecution() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            plan: { _ in NavigationPlan(commands: [.pop]) }
        )

        let result = handler.handle(URL(string: "myapp://myapp.com/settings")!)
        guard case .applicationRejected(let plan, let failure) = result else {
            Issue.record("Expected applicationRejected result")
            return
        }
        #expect(plan.commands == [.pop])
        #expect(failure.index == 0)
        #expect(failure.command == .pop)
        #expect(failure.result == .emptyStack)
        #expect(store.state.path.isEmpty)
    }

    @Test("Resume pending validates plan before execution")
    @MainActor
    func testResumePendingDeepLinkValidatesPlanBeforeExecution() {
        let store = NavigationStore<TestRoute>()
        let authState = Mutex(false)
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/settings") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { authState.withLock { $0 } }
            ),
            plan: { _ in NavigationPlan(commands: [.pop]) }
        )

        let pending = handler.handle(URL(string: "myapp://myapp.com/settings")!)
        guard case .pending = pending else {
            Issue.record("Expected pending result")
            return
        }

        authState.withLock { $0 = true }
        let resumed = handler.resumePendingDeepLink()
        guard case .applicationRejected(let plan, let failure) = resumed else {
            Issue.record("Expected applicationRejected result")
            return
        }
        #expect(plan.commands == [.pop])
        #expect(failure.result == .emptyStack)
        #expect(handler.pendingDeepLink == nil)
        #expect(store.state.path.isEmpty)
    }

    @Test("Unhandled decision preserves original URL")
    @MainActor
    func testUnhandledURLIsPreserved() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/known") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher
        )
        let url = URL(string: "myapp://myapp.com/unknown")!

        let result = handler.handle(url)
        guard case .unhandled(let unhandledURL) = result else {
            Issue.record("Expected unhandled result")
            return
        }
        #expect(unhandledURL == url)
    }

    @Test("Invalid URL string returns invalidURL result")
    @MainActor
    func testInvalidURLStringReturnsTypedResult() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/known") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher
        )

        let result = handler.handle("://invalid url")

        #expect(result == .invalidURL(input: "://invalid url"))
    }

    @Test("Missing effect URL returns missingDeepLinkURL result")
    @MainActor
    func testMissingEffectURLReturnsTypedResult() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/known") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher
        )

        let result = handler.handle(MockDeepLinkEffect(deepLinkURL: nil))

        #expect(result == .missingDeepLinkURL)
    }

    @Test("No pending deep link returns noPendingDeepLink result")
    @MainActor
    func testNoPendingDeepLinkReturnsTypedResult() {
        let store = NavigationStore<TestRoute>()
        let matcher = DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/known") { _ in .settings }
        }
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(store),
            matcher: matcher
        )

        let result = handler.resumePendingDeepLink()

        #expect(result == .noPendingDeepLink)
    }
}
