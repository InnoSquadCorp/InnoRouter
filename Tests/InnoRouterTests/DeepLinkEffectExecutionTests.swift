// MARK: - DeepLinkEffectExecutionTests.swift
// InnoRouter Tests - Deep-link effect execution contracts
// Copyright © 2025 Inno Squad. All rights reserved.

import Foundation
import Synchronization
import Testing
import InnoRouterEffects
@testable import InnoRouterSwiftUI

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

@Suite("Deep-link effect execution tests")
struct DeepLinkEffectExecutionTests {
    // A multi-command plan makes batch coalescing and partial execution observable.
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
            matcher: DeepLinkMatcher<TestRoute> {
                DeepLinkMapping("/link") { _ in .settings }
            },
            authenticationPolicy: authenticationPolicy,
            plan: { _ in NavigationPlan(commands: planCommands) }
        )
    }

    @MainActor
    private static func makeHandler(
        recorder: ExecutionRecorder,
        authenticationPolicy: DeepLinkAuthenticationPolicy<TestRoute> = .notRequired,
        cancelPredicate: (@MainActor @Sendable (NavigationCommand<TestRoute>) -> Bool)? = nil
    ) -> (DeepLinkEffectHandler<TestRoute>, NavigationStore<TestRoute>) {
        let store = NavigationStore<TestRoute>(
            configuration: recorder.configuration(cancelPredicate: cancelPredicate)
        )
        let handler = DeepLinkEffectHandler(
            pipeline: pipeline(authenticationPolicy: authenticationPolicy),
            navigator: AnyBatchNavigator(store)
        )
        return (handler, store)
    }

    @Test("Deep-link plan coalesces changed into one event")
    @MainActor
    func changedEventIsCoalesced() {
        let recorder = ExecutionRecorder()
        let (handler, store) = Self.makeHandler(recorder: recorder)

        _ = handler.handle(Self.url)

        #expect(recorder.changeCount == 1)
        #expect(store.state.path == Self.expectedPath)
    }

    @Test("Deep-link plan preserves middleware will/did order")
    @MainActor
    func middlewareOrderIsPreserved() {
        let recorder = ExecutionRecorder()
        let (handler, _) = Self.makeHandler(recorder: recorder)

        _ = handler.handle(Self.url)

        #expect(recorder.willExecuteCommands == Self.planCommands)
        #expect(
            recorder.didExecuteOutcomes == [
                .init(command: .replace([.home]), result: .success),
                .init(command: .push(.detail(id: "123")), result: .success),
                .init(command: .push(.settings), result: .success),
            ]
        )
    }

    @Test("Deep-link plan emits one batchExecuted event with complete metadata")
    @MainActor
    func batchExecutedMetadataIsComplete() throws {
        let recorder = ExecutionRecorder()
        let (handler, _) = Self.makeHandler(recorder: recorder)

        let outcome = handler.handle(Self.url)

        let emittedBatch = try #require(recorder.batchResults.first)
        #expect(recorder.batchResults.count == 1)
        #expect(emittedBatch.requestedCommands == Self.planCommands)
        #expect(emittedBatch.executedCommands == Self.planCommands)
        #expect(emittedBatch.results == Self.expectedBatchResults)
        #expect(emittedBatch.hasStoppedOnFailure == false)

        guard case .executed(let plan, let outcomeBatch) = outcome else {
            Issue.record("Expected .executed, got \(outcome)")
            return
        }
        #expect(plan.commands == Self.planCommands)
        #expect(outcomeBatch == emittedBatch)
    }

    @Test("Intermediate cancellation returns executionFailed and preserves partial path")
    @MainActor
    func intermediateCancellationPreservesPartialPath() throws {
        let recorder = ExecutionRecorder()
        let (handler, store) = Self.makeHandler(
            recorder: recorder,
            cancelPredicate: { command in
                if case .push(.detail) = command { return true }
                return false
            }
        )

        let outcome = handler.handle(Self.url)

        guard case .executionFailed(let plan, let outcomeBatch) = outcome else {
            Issue.record("Expected .executionFailed, got \(outcome)")
            return
        }
        let emittedBatch = try #require(recorder.batchResults.first)
        #expect(recorder.batchResults.count == 1)
        #expect(plan.commands == Self.planCommands)
        #expect(outcomeBatch == emittedBatch)
        #expect(outcomeBatch.results == [.success, .cancelled(.custom("test-cancel")), .success])
        #expect(outcomeBatch.isSuccess == false)
        #expect(store.state.path == [.home, .settings])
    }

    @Test("Pending replay emits navigation observations only after resume")
    @MainActor
    func pendingResumeObservation() throws {
        let authenticationState = Mutex(false)
        let recorder = ExecutionRecorder()
        let (handler, store) = Self.makeHandler(
            recorder: recorder,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { authenticationState.withLock { $0 } }
            )
        )

        let pendingOutcome = handler.handle(Self.url)

        guard case .pending = pendingOutcome else {
            Issue.record("Expected .pending, got \(pendingOutcome)")
            return
        }
        #expect(handler.pendingDeepLink != nil)
        #expect(recorder.changeCount == 0)
        #expect(recorder.batchResults.isEmpty)
        #expect(store.state.path.isEmpty)

        authenticationState.withLock { $0 = true }
        let resumedOutcome = handler.resumePendingDeepLink()

        guard case .executed(_, let outcomeBatch) = resumedOutcome else {
            Issue.record("Expected .executed, got \(resumedOutcome)")
            return
        }
        let emittedBatch = try #require(recorder.batchResults.first)
        #expect(recorder.changeCount == 1)
        #expect(recorder.batchResults.count == 1)
        #expect(outcomeBatch == emittedBatch)
        #expect(emittedBatch.requestedCommands == Self.planCommands)
        #expect(emittedBatch.executedCommands == Self.planCommands)
        #expect(emittedBatch.results == Self.expectedBatchResults)
        #expect(store.state.path == Self.expectedPath)
        #expect(handler.pendingDeepLink == nil)
    }
}
