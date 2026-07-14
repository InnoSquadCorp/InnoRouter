// MARK: - DeepLinkPathEquivalenceTests.swift
// InnoRouter Tests - Umbrella vs Effects deep-link execution parity
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import Observation
import Synchronization
import SwiftUI
import InnoRouter
import InnoRouterEffects
@testable import InnoRouterSwiftUI

// MARK: - Test Coordinator

private extension DeepLinkPathEquivalenceTests {
    @Observable
    @MainActor
    final class EquivalenceCoordinator: DeepLinkCoordinating {
        typealias RouteType = TestRoute
        typealias Destination = EmptyView

        let store: NavigationStore<TestRoute>
        var pendingDeepLink: PendingDeepLink<TestRoute>?
        let deepLinkPipeline: DeepLinkPipeline<TestRoute>

        init(
            configuration: NavigationStoreConfiguration<TestRoute>,
            deepLinkPipeline: DeepLinkPipeline<TestRoute>
        ) {
            self.store = NavigationStore<TestRoute>(configuration: configuration)
            self.deepLinkPipeline = deepLinkPipeline
        }

        @ViewBuilder
        func destination(for route: TestRoute) -> EmptyView {
            EmptyView()
        }
    }
}

// MARK: - Observation Recorder

@MainActor
private final class ExecutionRecorder {
    struct MiddlewareOutcome: Equatable {
        let command: NavigationCommand<TestRoute>
        let result: NavigationResult<TestRoute>
    }

    private(set) var changeCount = 0
    private(set) var batchResults: [NavigationBatchResult<TestRoute>] = []
    private(set) var willExecuteCommands: [NavigationCommand<TestRoute>] = []
    private(set) var didExecuteOutcomes: [MiddlewareOutcome] = []

    func configuration(
        cancelPredicate: (@MainActor @Sendable (NavigationCommand<TestRoute>) -> Bool)? = nil
    ) -> NavigationStoreConfiguration<TestRoute> {
        let middleware = AnyNavigationMiddleware<TestRoute>(
            willExecute: { [weak self] command, _ in
                self?.willExecuteCommands.append(command)
                if let cancelPredicate, cancelPredicate(command) {
                    return .cancel(.custom("test-cancel"))
                }
                return .proceed(command)
            },
            didExecute: { [weak self] command, result, _ in
                self?.didExecuteOutcomes.append(.init(command: command, result: result))
                return result
            }
        )
        return NavigationStoreConfiguration<TestRoute>(
            middlewares: [.init(middleware: middleware, debugName: "recorder")],
            onEvent: { [weak self] event in
                switch event {
                case .changed:
                    self?.changeCount += 1
                case .batchExecuted(let batch):
                    self?.batchResults.append(batch)
                default:
                    break
                }
            }
        )
    }
}

// MARK: - Suite

@Suite("DeepLink Plan Path Equivalence Tests")
struct DeepLinkPathEquivalenceTests {
    // Plan reused across tests. A multi-command plan is required so .changed
    // coalescing (1 event for batch vs N for for-loop) is observable.
    static let planCommands: [NavigationCommand<TestRoute>] = [
        .replace([.home]),
        .push(.detail(id: "123")),
        .push(.settings)
    ]
    static let expectedPath: [TestRoute] = [.home, .detail(id: "123"), .settings]
    static let expectedBatchResults: [NavigationResult<TestRoute>] = [.success, .success, .success]
    static let url = URL(string: "myapp://myapp.com/link")!

    private static func pipeline(
        authenticationPolicy: DeepLinkAuthenticationPolicy<TestRoute> = .notRequired
    ) -> DeepLinkPipeline<TestRoute> {
        DeepLinkPipeline<TestRoute>(
            matcher: matcher(),
            authenticationPolicy: authenticationPolicy,
            plan: { _ in NavigationPlan(commands: planCommands) }
        )
    }

    private static func matcher() -> DeepLinkMatcher<TestRoute> {
        DeepLinkMatcher<TestRoute> {
            DeepLinkMapping("/link") { _ in .settings }
        }
    }

    // MARK: Changed-event parity

    @Test("Umbrella and Effects paths coalesce changed into a single event")
    @MainActor
    func testChangedEventParity() {
        let umbrellaRecorder = ExecutionRecorder()
        let umbrella = EquivalenceCoordinator(
            configuration: umbrellaRecorder.configuration(),
            deepLinkPipeline: Self.pipeline()
        )
        umbrella.handleDeepLink(Self.url)

        let effectsRecorder = ExecutionRecorder()
        let effectsStore = NavigationStore<TestRoute>(configuration: effectsRecorder.configuration())
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(effectsStore),
            matcher: Self.matcher(),
            plan: { _ in NavigationPlan(commands: Self.planCommands) }
        )
        _ = handler.handle(Self.url)

        #expect(umbrellaRecorder.changeCount == 1)
        #expect(effectsRecorder.changeCount == 1)
        #expect(umbrella.store.state.path == Self.expectedPath)
        #expect(effectsStore.state.path == Self.expectedPath)
        #expect(umbrella.store.state.path == effectsStore.state.path)
    }

    // MARK: middleware sequence parity

    @Test("Middleware willExecute/didExecute sequences are identical across paths")
    @MainActor
    func testMiddlewareSequenceParity() {
        let umbrellaRecorder = ExecutionRecorder()
        let umbrella = EquivalenceCoordinator(
            configuration: umbrellaRecorder.configuration(),
            deepLinkPipeline: Self.pipeline()
        )
        umbrella.handleDeepLink(Self.url)

        let effectsRecorder = ExecutionRecorder()
        let effectsStore = NavigationStore<TestRoute>(configuration: effectsRecorder.configuration())
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(effectsStore),
            matcher: Self.matcher(),
            plan: { _ in NavigationPlan(commands: Self.planCommands) }
        )
        _ = handler.handle(Self.url)

        #expect(umbrellaRecorder.willExecuteCommands == effectsRecorder.willExecuteCommands)
        #expect(umbrellaRecorder.didExecuteOutcomes == effectsRecorder.didExecuteOutcomes)
        #expect(umbrellaRecorder.willExecuteCommands == Self.planCommands)
        #expect(
            umbrellaRecorder.didExecuteOutcomes == [
                .init(command: .replace([.home]), result: .success),
                .init(command: .push(.detail(id: "123")), result: .success),
                .init(command: .push(.settings), result: .success),
            ]
        )
    }

    // MARK: Batch-executed parity

    @Test("Both paths emit batchExecuted exactly once with equal metadata")
    @MainActor
    func testBatchExecutedEventParity() {
        let umbrellaRecorder = ExecutionRecorder()
        let umbrella = EquivalenceCoordinator(
            configuration: umbrellaRecorder.configuration(),
            deepLinkPipeline: Self.pipeline()
        )
        umbrella.handleDeepLink(Self.url)

        let effectsRecorder = ExecutionRecorder()
        let effectsStore = NavigationStore<TestRoute>(configuration: effectsRecorder.configuration())
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(effectsStore),
            matcher: Self.matcher(),
            plan: { _ in NavigationPlan(commands: Self.planCommands) }
        )
        _ = handler.handle(Self.url)

        #expect(umbrellaRecorder.batchResults.count == 1)
        #expect(effectsRecorder.batchResults.count == 1)

        let umbrellaBatch = umbrellaRecorder.batchResults[0]
        let effectsBatch = effectsRecorder.batchResults[0]
        #expect(umbrellaBatch.requestedCommands == Self.planCommands)
        #expect(effectsBatch.requestedCommands == Self.planCommands)
        #expect(umbrellaBatch.requestedCommands == effectsBatch.requestedCommands)
        #expect(umbrellaBatch.executedCommands == Self.planCommands)
        #expect(effectsBatch.executedCommands == Self.planCommands)
        #expect(umbrellaBatch.executedCommands == effectsBatch.executedCommands)
        #expect(umbrellaBatch.results == Self.expectedBatchResults)
        #expect(effectsBatch.results == Self.expectedBatchResults)
        #expect(umbrellaBatch.results == effectsBatch.results)
        #expect(umbrellaBatch.hasStoppedOnFailure == false)
        #expect(effectsBatch.hasStoppedOnFailure == false)
    }

    // MARK: partial failure parity

    @Test("Cancelled intermediate command does not stop the plan on either path")
    @MainActor
    func testPartialFailureParity() {
        let cancelPredicate: @MainActor @Sendable (NavigationCommand<TestRoute>) -> Bool = { command in
            if case .push(.detail) = command { return true }
            return false
        }

        let umbrellaRecorder = ExecutionRecorder()
        let umbrella = EquivalenceCoordinator(
            configuration: umbrellaRecorder.configuration(cancelPredicate: cancelPredicate),
            deepLinkPipeline: Self.pipeline()
        )
        let umbrellaOutcome = umbrella.handleDeepLink(Self.url)

        let effectsRecorder = ExecutionRecorder()
        let effectsStore = NavigationStore<TestRoute>(
            configuration: effectsRecorder.configuration(cancelPredicate: cancelPredicate)
        )
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(effectsStore),
            matcher: Self.matcher(),
            plan: { _ in NavigationPlan(commands: Self.planCommands) }
        )
        let effectsOutcome = handler.handle(Self.url)

        guard case .executionFailed(let umbrellaPlan, let umbrellaOutcomeBatch) = umbrellaOutcome else {
            Issue.record("Expected Umbrella .executionFailed, got \(umbrellaOutcome)")
            return
        }
        guard case .executionFailed(let effectsPlan, let effectsOutcomeBatch) = effectsOutcome else {
            Issue.record("Expected Effects .executionFailed, got \(effectsOutcome)")
            return
        }

        #expect(umbrellaRecorder.batchResults.count == 1)
        #expect(effectsRecorder.batchResults.count == 1)

        let umbrellaBatch = umbrellaRecorder.batchResults[0]
        let effectsBatch = effectsRecorder.batchResults[0]
        #expect(umbrellaPlan.commands == Self.planCommands)
        #expect(effectsPlan.commands == Self.planCommands)
        #expect(umbrellaOutcomeBatch == umbrellaBatch)
        #expect(effectsOutcomeBatch == effectsBatch)
        #expect(umbrellaBatch.results == effectsBatch.results)
        #expect(umbrellaBatch.results == [.success, .cancelled(.custom("test-cancel")), .success])
        #expect(umbrellaBatch.isSuccess == false)
        #expect(umbrellaBatch.executedCommands == effectsBatch.executedCommands)
        #expect(umbrella.store.state.path == effectsStore.state.path)
        #expect(umbrella.store.state.path == [.home, .settings])
    }

    // MARK: pending resume parity

    @Test("Pending resume produces the same observation footprint as Effects resume")
    @MainActor
    func testPendingResumeParity() {
        let umbrellaAuthState = Mutex(false)
        let umbrellaRecorder = ExecutionRecorder()
        let umbrella = EquivalenceCoordinator(
            configuration: umbrellaRecorder.configuration(),
            deepLinkPipeline: Self.pipeline(
                authenticationPolicy: .required(
                    shouldRequireAuthentication: { _ in true },
                    isAuthenticated: { umbrellaAuthState.withLock { $0 } }
                )
            )
        )
        umbrella.handleDeepLink(Self.url)
        #expect(umbrella.pendingDeepLink != nil)
        #expect(umbrellaRecorder.changeCount == 0)
        #expect(umbrellaRecorder.batchResults.isEmpty)

        umbrellaAuthState.withLock { $0 = true }
        if case .executed = umbrella.resumePendingDeepLinkIfPossible() {
            // expected
        } else {
            Issue.record("expected .executed outcome from resumePendingDeepLinkIfPossible")
        }

        let effectsAuthState = Mutex(false)
        let effectsRecorder = ExecutionRecorder()
        let effectsStore = NavigationStore<TestRoute>(configuration: effectsRecorder.configuration())
        let handler = DeepLinkEffectHandler(
            navigator: AnyBatchNavigator(effectsStore),
            matcher: Self.matcher(),
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { effectsAuthState.withLock { $0 } }
            ),
            plan: { _ in NavigationPlan(commands: Self.planCommands) }
        )
        _ = handler.handle(Self.url)
        #expect(handler.pendingDeepLink != nil)
        #expect(effectsRecorder.changeCount == 0)
        #expect(effectsRecorder.batchResults.isEmpty)

        effectsAuthState.withLock { $0 = true }
        _ = handler.resumePendingDeepLink()

        #expect(umbrellaRecorder.changeCount == 1)
        #expect(effectsRecorder.changeCount == 1)
        #expect(umbrellaRecorder.batchResults.count == 1)
        #expect(effectsRecorder.batchResults.count == 1)

        let umbrellaBatch = umbrellaRecorder.batchResults[0]
        let effectsBatch = effectsRecorder.batchResults[0]
        #expect(umbrellaBatch.requestedCommands == Self.planCommands)
        #expect(effectsBatch.requestedCommands == Self.planCommands)
        #expect(umbrellaBatch.executedCommands == Self.planCommands)
        #expect(effectsBatch.executedCommands == Self.planCommands)
        #expect(umbrellaBatch.results == Self.expectedBatchResults)
        #expect(effectsBatch.results == Self.expectedBatchResults)
        #expect(umbrella.store.state.path == Self.expectedPath)
        #expect(effectsStore.state.path == Self.expectedPath)

        #expect(umbrellaRecorder.changeCount == effectsRecorder.changeCount)
        #expect(umbrellaRecorder.batchResults.count == effectsRecorder.batchResults.count)
        #expect(umbrellaBatch.results == effectsBatch.results)
        #expect(umbrella.store.state.path == effectsStore.state.path)
        #expect(umbrella.pendingDeepLink == nil)
        #expect(handler.pendingDeepLink == nil)
    }
}
