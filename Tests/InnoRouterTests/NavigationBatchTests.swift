// MARK: - NavigationBatchTests.swift
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

// MARK: - NavigationBatch Tests

@Suite("NavigationBatch Tests")
struct NavigationBatchTests {
    @Test("Execute batch records snapshots, middleware, and observer once")
    @MainActor
    func testExecuteBatchCapturesSnapshots() throws {
        var changeCount = 0
        var observedBatch: NavigationBatchResult<TestRoute>?
        let store = try NavigationStore<TestRoute>(
            initialPath: [.home],
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    switch event {
                    case .changed:
                        changeCount += 1
                    case .batchExecuted(let batch):
                        observedBatch = batch
                    default:
                        break
                    }
                }
            )
        )
        var willCount = 0
        var didCount = 0
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    willCount += 1
                    return .proceed(command)
                },
                didExecute: { _, result, _ in
                    didCount += 1
                    return result
                }
            )
        )

        let batch = store.executeBatch([.push(.detail(id: "123")), .push(.settings)])

        #expect(batch.requestedCommands == [.push(.detail(id: "123")), .push(.settings)])
        #expect(batch.executedCommands == [.push(.detail(id: "123")), .push(.settings)])
        #expect(batch.results == [.success, .success])
        #expect(batch.stateBefore == (try validatedStack([.home])))
        #expect(batch.stateAfter == (try validatedStack([.home, .detail(id: "123"), .settings])))
        #expect(batch.hasStoppedOnFailure == false)
        #expect(batch.isSuccess == true)
        #expect(store.state == batch.stateAfter)
        #expect(changeCount == 1)
        #expect(observedBatch == batch)
        #expect(willCount == 2)
        #expect(didCount == 2)
    }

    @Test("Execute batch can stop on first failure")
    @MainActor
    func testExecuteBatchStopOnFailure() throws {
        var changeCount = 0
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    guard case .changed = event else { return }
                    changeCount += 1
                }
            )
        )

        let batch = store.executeBatch(
            [.push(.home), .popCount(5), .push(.settings)],
            stopOnFailure: true
        )

        #expect(batch.requestedCommands == [.push(.home), .popCount(5), .push(.settings)])
        #expect(batch.executedCommands == [.push(.home), .popCount(5)])
        #expect(batch.results == [.success, .insufficientStackDepth(requested: 5, available: 1)])
        #expect(batch.stateBefore == RouteStack<TestRoute>())
        #expect(batch.stateAfter == (try validatedStack([.home])))
        #expect(batch.hasStoppedOnFailure == true)
        #expect(batch.isSuccess == false)
        #expect(store.state.path == [.home])
        #expect(changeCount == 1)
    }

    @Test("Execute batch stopOnFailure uses middleware-folded failures")
    @MainActor
    func testExecuteBatchStopOnMiddlewareFoldedFailure() {
        let store = NavigationStore<TestRoute>()
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in .proceed(command) },
                didExecute: { command, result, _ in
                    if case .push(.home) = command {
                        return .cancelled(.custom("folded failure"))
                    }
                    return result
                }
            ),
            debugName: "fold"
        )

        let batch = store.executeBatch([.push(.home), .push(.settings)], stopOnFailure: true)

        #expect(batch.executedCommands == [.push(.home)])
        #expect(batch.results == [.cancelled(.custom("folded failure"))])
        #expect(batch.hasStoppedOnFailure == true)
        #expect(store.state.path == [.home])
    }

    @Test("Execute batch continues when middleware normalizes a raw failure to success")
    @MainActor
    func testExecuteBatchContinuesWhenMiddlewareNormalizesFailure() {
        let store = NavigationStore<TestRoute>()
        store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in .proceed(command) },
                didExecute: { command, result, _ in
                    if case .pop = command {
                        return .success
                    }
                    return result
                }
            ),
            debugName: "normalize"
        )

        let batch = store.executeBatch([.pop, .push(.home)], stopOnFailure: true)

        #expect(batch.executedCommands == [.pop, .push(.home)])
        #expect(batch.results == [.success, .success])
        #expect(batch.hasStoppedOnFailure == false)
        #expect(batch.isSuccess == true)
        #expect(store.state.path == [.home])
    }

    @Test("Execute batch records middleware-rewritten commands")
    @MainActor
    func testExecuteBatchTracksActualExecutedCommands() {
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
                }
            ),
            debugName: "rewrite"
        )

        let batch = store.executeBatch([.push(.home), .push(.detail(id: "123"))])

        #expect(batch.requestedCommands == [.push(.home), .push(.detail(id: "123"))])
        #expect(batch.executedCommands == [.push(.settings), .push(.detail(id: "123"))])
        #expect(store.state.path == [.settings, .detail(id: "123")])
    }

    @Test("Sequence and batch keep different observation semantics")
    @MainActor
    func testSequenceAndBatchObservationDifference() {
        var sequenceChanges = 0
        var sequenceBatchCount = 0
        let sequenceStore = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    switch event {
                    case .changed:
                        sequenceChanges += 1
                    case .batchExecuted:
                        sequenceBatchCount += 1
                    default:
                        break
                    }
                }
            )
        )

        _ = sequenceStore.execute(.sequence([.push(.home), .push(.settings)]))

        var batchChanges = 0
        var batchObserverCount = 0
        let batchStore = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    switch event {
                    case .changed:
                        batchChanges += 1
                    case .batchExecuted:
                        batchObserverCount += 1
                    default:
                        break
                    }
                }
            )
        )

        _ = batchStore.executeBatch([.push(.home), .push(.settings)])

        #expect(sequenceStore.state == batchStore.state)
        #expect(sequenceChanges == 2)
        #expect(sequenceBatchCount == 0)
        #expect(batchChanges == 1)
        #expect(batchObserverCount == 1)
    }

    @Test("Middleware handles support insert move replace and remove")
    @MainActor
    func testMiddlewareHandleOperations() {
        let store = NavigationStore<TestRoute>()
        var invocationOrder: [String] = []

        let first = store.addMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    invocationOrder.append("first")
                    return .proceed(command)
                }
            ),
            debugName: "first"
        )
        let second = store.insertMiddleware(
            AnyNavigationMiddleware(
                willExecute: { command, _ in
                    invocationOrder.append("second")
                    return .proceed(command)
                }
            ),
            at: 0,
            debugName: "second"
        )
        #expect(store.middlewareHandles == [second, first])
        #expect(store.middlewareMetadata.map(\.debugName) == ["second", "first"])

        let moved = store.moveMiddleware(first, to: 0)
        #expect(moved == true)
        #expect(store.middlewareHandles == [first, second])
        #expect(store.middlewareMetadata.map(\.debugName) == ["first", "second"])

        let replaced = store.replaceMiddleware(
            second,
            with: AnyNavigationMiddleware(
                willExecute: { command, _ in
                    invocationOrder.append("second-replaced")
                    return .proceed(command)
                }
            ),
            debugName: "second-replaced"
        )
        #expect(replaced == true)
        #expect(store.middlewareMetadata.map(\.debugName) == ["first", "second-replaced"])

        _ = store.execute(.push(.home))
        #expect(invocationOrder == ["first", "second-replaced"])

        let removed = store.removeMiddleware(first)
        #expect(removed != nil)
        #expect(store.middlewareHandles == [second])
        #expect(store.middlewareMetadata.map(\.debugName) == ["second-replaced"])

        invocationOrder.removeAll()
        _ = store.execute(.push(.settings))
        #expect(invocationOrder == ["second-replaced"])
    }

    @Test("Initializer middlewares receive stable handles in order")
    @MainActor
    func testInitializerMiddlewaresReceiveHandles() {
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    NavigationMiddlewareRegistration(
                        middleware: AnyNavigationMiddleware(willExecute: { command, _ in .proceed(command) }),
                        debugName: "first"
                    ),
                    NavigationMiddlewareRegistration(
                        middleware: AnyNavigationMiddleware(willExecute: { command, _ in .proceed(command) }),
                        debugName: "second"
                    )
                ]
            )
        )

        #expect(store.middlewareHandles.count == 2)
        #expect(Set(store.middlewareHandles).count == 2)
        #expect(store.middlewareMetadata.map(\.debugName) == ["first", "second"])
    }
}
