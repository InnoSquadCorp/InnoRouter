// MARK: - CoordinatorDeepLinkTests.swift
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

// MARK: - Coordinator DeepLink Tests

@Suite("Coordinator DeepLink Tests")
struct CoordinatorDeepLinkTests {
    @Observable
    @MainActor
    final class DeepLinkCoordinator: DeepLinkCoordinating {
        typealias RouteType = TestRoute
        typealias Destination = EmptyView

        let store = NavigationStore<TestRoute>()

        var pendingDeepLink: PendingDeepLink<TestRoute>?
        let deepLinkPipeline: DeepLinkPipeline<TestRoute>

        init(deepLinkPipeline: DeepLinkPipeline<TestRoute>) {
            self.deepLinkPipeline = deepLinkPipeline
        }

        @ViewBuilder
        func destination(for route: TestRoute) -> EmptyView {
            EmptyView()
        }
    }

    @Test("DeepLink plan executes into store")
    @MainActor
    func testDeepLinkPlanExecutes() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .settings }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)

        let outcome = coordinator.handleDeepLink(URL(string: "myapp://myapp.com/anything")!)

        guard case .executed(let plan, _) = outcome else {
            Issue.record("expected .executed, got \(outcome)")
            return
        }
        #expect(plan.commands == [.push(.settings)])
        #expect(coordinator.store.state.path.last == .settings)
        #expect(coordinator.pendingDeepLink == nil)
    }

    @Test("handleDeepLink returns .rejected for disallowed scheme")
    @MainActor
    func testHandleDeepLinkReturnsRejectedForDisallowedScheme() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            allowedSchemes: ["myapp"],
            customResolver: { _ in .settings }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)

        let outcome = coordinator.handleDeepLink(URL(string: "https://other.com/secure")!)

        guard case .rejected(let reason) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(reason == .schemeNotAllowed(actualScheme: "https"))
        #expect(coordinator.store.state.path.isEmpty)
        #expect(coordinator.pendingDeepLink == nil)
    }

    @Test("handleDeepLink returns .unhandled for unresolved URL")
    @MainActor
    func testHandleDeepLinkReturnsUnhandledForUnresolvedURL() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in nil }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)
        let url = URL(string: "myapp://myapp.com/nowhere")!

        let outcome = coordinator.handleDeepLink(url)

        guard case .unhandled(let unhandledURL) = outcome else {
            Issue.record("expected .unhandled, got \(outcome)")
            return
        }
        #expect(unhandledURL == url)
        #expect(coordinator.store.state.path.isEmpty)
        #expect(coordinator.pendingDeepLink == nil)
    }

    @Test("DeepLink pending is stored")
    @MainActor
    func testDeepLinkPendingStored() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            allowedSchemes: ["myapp"],
            allowedHosts: ["myapp.com"],
            customResolver: { _ in .settings },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            )
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)

        coordinator.handleDeepLink(URL(string: "myapp://myapp.com/secure")!)

        #expect(coordinator.store.state.path.isEmpty)
        #expect(coordinator.pendingDeepLink?.route == .settings)
        #expect(coordinator.pendingDeepLink?.plan.commands == [.push(.settings)])
    }

    @Test("Pending deep link preserves planned commands")
    @MainActor
    func testPendingDeepLinkPreservesPlan() {
        let planCommands: [NavigationCommand<TestRoute>] = [
            .replace([.home, .settings]),
            .push(.detail(id: "123"))
        ]
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .settings },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            ),
            plan: { _ in NavigationPlan(commands: planCommands) }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)

        coordinator.handleDeepLink(URL(string: "myapp://myapp.com/secure")!)

        #expect(coordinator.pendingDeepLink?.plan.commands == planCommands)
    }

    @Test("DeepLink plan validation rejection prevents store execution")
    @MainActor
    func testDeepLinkPlanValidationRejectionPreventsExecution() {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .settings },
            plan: { _ in NavigationPlan(commands: [.pop]) }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)

        let outcome = coordinator.handleDeepLink(URL(string: "myapp://myapp.com/settings")!)

        guard case .applicationRejected(let plan, let failure) = outcome else {
            Issue.record("expected .applicationRejected, got \(outcome)")
            return
        }
        #expect(plan.commands == [.pop])
        #expect(failure.result == .emptyStack)
        #expect(coordinator.store.state.path.isEmpty)
        #expect(coordinator.pendingDeepLink == nil)
    }

    @Test("Async coordinator deep-link guard keeps pending until authorized")
    @MainActor
    func testResumePendingDeepLinkIfAllowed() async {
        let authState = Mutex(false)
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { _ in .settings },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { authState.withLock { $0 } }
            ),
            plan: { _ in NavigationPlan(commands: [.replace([.home, .settings])]) }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)
        coordinator.handleDeepLink(URL(string: "myapp://myapp.com/secure")!)

        let denied = await coordinator.resumePendingDeepLinkIfAllowed { _ in false }
        if case .pending = denied {
            // expected
        } else {
            Issue.record("expected .pending after denied authorization, got \(denied)")
        }
        #expect(coordinator.pendingDeepLink != nil)
        #expect(coordinator.store.state.path.isEmpty)

        authState.withLock { $0 = true }
        let resumed = await coordinator.resumePendingDeepLinkIfAllowed { _ in true }
        if case .executed = resumed {
            // expected
        } else {
            Issue.record("expected .executed after authorization, got \(resumed)")
        }
        #expect(coordinator.pendingDeepLink == nil)
        #expect(coordinator.store.state.path == [.home, .settings])
    }

    @Test("Async coordinator deep-link guard does not resume stale pending deep links")
    @MainActor
    func testResumePendingDeepLinkIfAllowedUsesCurrentPendingIdentity() async {
        let pipeline = DeepLinkPipeline<TestRoute>(
            customResolver: { url in
                url.path.contains("home") ? .home : .settings
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { false }
            ),
            plan: { route in NavigationPlan(commands: [.push(route)]) }
        )
        let coordinator = DeepLinkCoordinator(deepLinkPipeline: pipeline)
        coordinator.handleDeepLink(URL(string: "myapp://myapp.com/settings")!)

        let resumed = await coordinator.resumePendingDeepLinkIfAllowed { _ in
            coordinator.handleDeepLink(URL(string: "myapp://myapp.com/home")!)
            return false
        }

        guard case .pending(let current) = resumed else {
            Issue.record("expected .pending after stale identity, got \(resumed)")
            return
        }
        #expect(current.route == .home)
        #expect(coordinator.pendingDeepLink?.route == .home)
        #expect(coordinator.store.state.path.isEmpty)
    }
}
