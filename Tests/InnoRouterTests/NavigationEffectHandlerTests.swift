// MARK: - NavigationEffectHandlerTests.swift
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

// MARK: - NavigationEffectHandler Tests

@Suite("NavigationEffectHandler Tests")
struct NavigationEffectHandlerTests {
    @Test("execute(_:stopOnFailure:) returns batch result and preserves middleware order")
    @MainActor
    func testExecuteStopOnFailure() async throws {
        var changeCount = 0
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    guard case .changed = event else { return }
                    changeCount += 1
                }
            )
        )
        var willExecuteCount = 0
        var didExecuteCount = 0
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    willExecuteCount += 1
                    return .proceed(command)
                },
                didExecute: { _, result, _ in
                    didExecuteCount += 1
                    return result
                }
            )
        )

        let handler = NavigationEffectHandler(navigator: AnyBatchNavigator(store))
        var iterator = handler.events.makeAsyncIterator()
        let batch = handler.execute(
            [
                .push(.home),
                .popCount(5),
                .push(.settings)
            ],
            stopOnFailure: true
        )

        #expect(batch.requestedCommands == [.push(.home), .popCount(5), .push(.settings)])
        #expect(batch.executedCommands == [.push(.home), .popCount(5)])
        #expect(batch.results == [.success, .insufficientStackDepth(requested: 5, available: 1)])
        #expect(batch.hasStoppedOnFailure == true)
        #expect(batch.stateBefore == RouteStack<TestRoute>())
        #expect(batch.stateAfter == (try validatedStack([.home])))
        #expect(store.state.path == [.home])
        #expect(willExecuteCount == 2)
        #expect(didExecuteCount == 2)
        #expect(changeCount == 1)
        guard case .batch(let commands, let eventBatch) = await iterator.next() else {
            Issue.record("Expected .batch event")
            return
        }
        #expect(commands == [.push(.home), .popCount(5), .push(.settings)])
        #expect(eventBatch == batch)
    }

    @Test("AnyBatchNavigator convenience methods surface typed results")
    @MainActor
    func testAnyBatchNavigatorConvenienceMethodsReturnResults() {
        let navigator = AnyBatchNavigator(NavigationStore<TestRoute>())

        let popToRootResult = navigator.popToRoot()
        let replaceResult = navigator.replace(with: [.home])

        #expect(popToRootResult == .success)
        #expect(replaceResult == .success)
    }

    @Test("single execute clears stale batch result")
    @MainActor
    func testSingleExecuteClearsBatchResult() async {
        let store = NavigationStore<TestRoute>()
        let handler = NavigationEffectHandler(navigator: AnyBatchNavigator(store))
        var iterator = handler.events.makeAsyncIterator()

        let batch = handler.execute([.push(.home), .push(.settings)])
        #expect(batch.results == [.success, .success])
        guard case .batch(_, let eventBatch) = await iterator.next() else {
            Issue.record("Expected .batch event")
            return
        }
        #expect(eventBatch == batch)

        let single = handler.execute(.pop)

        #expect(single == .success)
        guard case .command(let command, let result) = await iterator.next() else {
            Issue.record("Expected .command event")
            return
        }
        #expect(command == .pop)
        #expect(result == .success)
        #expect(store.state.path == [.home])
    }

    @Test("executeTransaction returns atomic transaction result")
    @MainActor
    func testExecuteTransaction() async throws {
        let store = NavigationStore<TestRoute>()
        let handler = NavigationEffectHandler(navigator: AnyBatchNavigator(store))
        var iterator = handler.events.makeAsyncIterator()

        let transaction = handler.executeTransaction([.push(.home), .push(.settings)])

        #expect(transaction.isCommitted == true)
        #expect(transaction.results == [.success, .success])
        #expect(transaction.stateAfter == (try validatedStack([.home, .settings])))
        #expect(store.state.path == [.home, .settings])
        guard case .transaction(let commands, let eventTransaction) = await iterator.next() else {
            Issue.record("Expected .transaction event")
            return
        }
        #expect(commands == [.push(.home), .push(.settings)])
        #expect(eventTransaction == transaction)
    }

    @Test("executeGuarded cancels without mutating state")
    @MainActor
    func testExecuteGuardedCancel() async {
        let store = NavigationStore<TestRoute>()
        let handler = NavigationEffectHandler(navigator: AnyBatchNavigator(store))
        var iterator = handler.events.makeAsyncIterator()

        let result = await handler.executeGuarded(.push(.home)) { command in
            .cancel(.middleware(debugName: "guard", command: command))
        }

        #expect(result == .cancelled(.middleware(debugName: "guard", command: .push(.home))))
        guard case .command(let command, let eventResult) = await iterator.next() else {
            Issue.record("Expected .command event")
            return
        }
        #expect(command == .push(.home))
        #expect(eventResult == result)
        #expect(store.state.path.isEmpty)
    }

    @Test("executeGuarded proceeds into synchronous execution")
    @MainActor
    func testExecuteGuardedProceed() async {
        let store = NavigationStore<TestRoute>()
        let handler = NavigationEffectHandler(navigator: AnyBatchNavigator(store))
        var iterator = handler.events.makeAsyncIterator()

        let result = await handler.executeGuarded(.push(.home)) { command in
            .proceed(command)
        }

        #expect(result == .success)
        guard case .command(let command, let eventResult) = await iterator.next() else {
            Issue.record("Expected .command event")
            return
        }
        #expect(command == .push(.home))
        #expect(eventResult == .success)
        #expect(store.state.path == [.home])
    }
}
