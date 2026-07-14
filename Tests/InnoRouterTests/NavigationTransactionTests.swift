// MARK: - NavigationTransactionTests.swift
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

// MARK: - NavigationTransaction Tests

@Suite("NavigationTransaction Tests")
struct NavigationTransactionTests {
    @Test("Execute transaction commits once and notifies observers once")
    @MainActor
    func testExecuteTransactionCommit() throws {
        var changeCount = 0
        var transactionObserver: NavigationTransactionResult<TestRoute>?
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    switch event {
                    case .changed:
                        changeCount += 1
                    case .transactionExecuted(let transaction):
                        transactionObserver = transaction
                    default:
                        break
                    }
                }
            )
        )
        var didExecuteOrder: [NavigationCommand<TestRoute>] = []
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in .proceed(command) },
                didExecute: { command, result, _ in
                    didExecuteOrder.append(command)
                    return result
                }
            ),
            debugName: "tracking"
        )

        let transaction = store.executeTransaction([.push(.home), .push(.settings)])

        #expect(transaction.isCommitted == true)
        #expect(transaction.failureIndex == nil)
        #expect(transaction.results == [.success, .success])
        #expect(transaction.stateBefore == RouteStack<TestRoute>())
        #expect(transaction.stateAfter == (try validatedStack([.home, .settings])))
        #expect(store.state == (try validatedStack([.home, .settings])))
        #expect(changeCount == 1)
        #expect(didExecuteOrder == [.push(.home), .push(.settings)])
        #expect(transactionObserver == transaction)
    }

    @Test("Execute transaction rolls back state on failure")
    @MainActor
    func testExecuteTransactionRollbackOnFailure() {
        var changeCount = 0
        var transactionObserver: NavigationTransactionResult<TestRoute>?
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    switch event {
                    case .changed:
                        changeCount += 1
                    case .transactionExecuted(let transaction):
                        transactionObserver = transaction
                    default:
                        break
                    }
                }
            )
        )
        var didExecuteCount = 0
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in .proceed(command) },
                didExecute: { _, result, _ in
                    didExecuteCount += 1
                    return result
                }
            )
        )

        let transaction = store.executeTransaction([.push(.home), .popCount(5)])

        #expect(transaction.isCommitted == false)
        #expect(transaction.failureIndex == 1)
        #expect(transaction.results == [.success, .insufficientStackDepth(requested: 5, available: 1)])
        #expect(transaction.stateBefore == RouteStack<TestRoute>())
        #expect(transaction.stateAfter == RouteStack<TestRoute>())
        #expect(store.state == RouteStack<TestRoute>())
        #expect(changeCount == 0)
        #expect(didExecuteCount == 0)
        #expect(transactionObserver == transaction)
    }

    @Test("Execute transaction uses rewritten commands and folded results")
    @MainActor
    func testExecuteTransactionUsesActualCommandsAndFoldedResults() throws {
        let store = NavigationStore<TestRoute>()
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    switch command {
                    case .push(.home):
                        return .proceed(.push(.settings))
                    default:
                        return .proceed(command)
                    }
                },
                didExecute: { command, result, _ in
                    if command == .push(.settings) {
                        return .multiple([result])
                    }
                    return result
                }
            ),
            debugName: "rewrite"
        )

        let transaction = store.executeTransaction([.push(.home), .push(.detail(id: "123"))])

        #expect(transaction.executedCommands == [.push(.settings), .push(.detail(id: "123"))])
        #expect(transaction.results == [.multiple([.success]), .success])
        #expect(transaction.isCommitted == true)
        #expect(store.state == (try validatedStack([.settings, .detail(id: "123")])))
    }

    @Test("Sequence preserves partial success while transaction rolls back")
    @MainActor
    func testSequenceAndTransactionDifferOnFailure() {
        let sequenceStore = NavigationStore<TestRoute>()
        let transactionStore = NavigationStore<TestRoute>()

        let sequenceResult = sequenceStore.execute(.sequence([.push(.home), .popCount(5)]))
        let transactionResult = transactionStore.executeTransaction([.push(.home), .popCount(5)])

        #expect(sequenceResult == .multiple([.success, .insufficientStackDepth(requested: 5, available: 1)]))
        #expect(sequenceStore.state.path == [.home])
        #expect(transactionResult.results == [.success, .insufficientStackDepth(requested: 5, available: 1)])
        #expect(transactionResult.isCommitted == false)
        #expect(transactionStore.state.path.isEmpty)
    }
}
