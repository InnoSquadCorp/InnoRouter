// MARK: - NavigationCommandWhenCancelledTests.swift
// InnoRouterTests - .whenCancelled fallback behaviour
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouterCore
import InnoRouter
import InnoRouterSwiftUI

private enum WCRoute: Route {
    case home
    case detail
    case settings
}

@MainActor
private func blockCommandMiddleware(
    predicate: @escaping @MainActor @Sendable (NavigationCommand<WCRoute>) -> Bool
) -> AnyNavigationMiddleware<WCRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in
        if predicate(command) {
            return .cancel(.middleware(debugName: "block", command: command))
        }
        return .proceed(command)
    })
}

@MainActor
private final class CleanupTrackingMiddleware: NavigationMiddleware, NavigationMiddlewareDiscardCleanup {
    typealias RouteType = WCRoute

    var didExecuteCommands: [NavigationCommand<WCRoute>] = []
    var discardedCommands: [NavigationCommand<WCRoute>] = []

    private let interceptor: @MainActor @Sendable (NavigationCommand<WCRoute>, RouteStack<WCRoute>) -> NavigationInterception<WCRoute>

    init(
        interceptor: @escaping @MainActor @Sendable (NavigationCommand<WCRoute>, RouteStack<WCRoute>) -> NavigationInterception<WCRoute>
    ) {
        self.interceptor = interceptor
    }

    func willExecute(
        _ command: NavigationCommand<WCRoute>,
        state: RouteStack<WCRoute>
    ) -> NavigationInterception<WCRoute> {
        interceptor(command, state)
    }

    func didExecute(
        _ command: NavigationCommand<WCRoute>,
        result: NavigationResult<WCRoute>,
        state: RouteStack<WCRoute>
    ) -> NavigationResult<WCRoute> {
        didExecuteCommands.append(command)
        return result
    }

    func discardExecution(
        _ command: NavigationCommand<WCRoute>,
        result: NavigationResult<WCRoute>,
        state: RouteStack<WCRoute>
    ) {
        discardedCommands.append(command)
    }
}

@Suite("NavigationCommand .whenCancelled Tests")
struct NavigationCommandWhenCancelledTests {

    @Test("Engine: primary succeeds → primary result, fallback untouched")
    func engineSuccessSkipsFallback() {
        let engine = NavigationEngine<WCRoute>()
        var state = RouteStack<WCRoute>()
        let result = engine.apply(
            .whenCancelled(.push(.home), fallback: .push(.detail)),
            to: &state
        )
        #expect(result.isSuccess)
        #expect(state.path == [.home])
    }

    @Test("Engine: primary engine-level failure rolls back and runs fallback")
    func engineFailureTriggersFallback() {
        let engine = NavigationEngine<WCRoute>()
        var state = RouteStack<WCRoute>()
        // pop on empty stack fails → fallback runs on rolled-back state
        let result = engine.apply(
            .whenCancelled(.pop, fallback: .push(.home)),
            to: &state
        )
        #expect(result.isSuccess)
        #expect(state.path == [.home])
    }

    @Test("Engine: primary with partial side effect rolls back before fallback")
    func engineSnapshotRollback() {
        let engine = NavigationEngine<WCRoute>()
        var state = RouteStack<WCRoute>()
        // sequence(push(home), pop on empty now filled, popTo(settings)) —
        // the last pop fails. State rolled back.
        let result = engine.apply(
            .whenCancelled(
                .sequence([.push(.home), .popTo(.settings)]),
                fallback: .push(.detail)
            ),
            to: &state
        )
        #expect(result.isSuccess)
        // partial .push(.home) rolled back; only fallback's push committed.
        #expect(state.path == [.detail])
    }

    @Test("Engine: failed fallback rolls back its partial state")
    func engineFailedFallbackRollsBack() {
        let engine = NavigationEngine<WCRoute>()
        var state = RouteStack<WCRoute>()

        let result = engine.apply(
            .whenCancelled(
                .pop,
                fallback: .sequence([.push(.home), .popTo(.settings)])
            ),
            to: &state
        )

        #expect(result == .multiple([.success, .routeNotFound(.settings)]))
        #expect(state.path.isEmpty)
    }

    @Test("Empty composite legs fail while concrete empty payloads succeed")
    @MainActor
    func emptyLegSemanticsStayExplicit() throws {
        let fallbackStore = NavigationStore<WCRoute>()
        let fallbackResult = fallbackStore.execute(
            .whenCancelled(.sequence([]), fallback: .push(.home))
        )
        #expect(fallbackResult == .success)
        #expect(fallbackStore.state.path == [.home])

        let failedFallbackStore = NavigationStore<WCRoute>()
        let failedFallbackResult = failedFallbackStore.execute(
            .whenCancelled(.pop, fallback: .sequence([]))
        )
        #expect(failedFallbackResult == .multiple([]))
        #expect(failedFallbackStore.state.path.isEmpty)

        let noOpStore = try NavigationStore<WCRoute>(initialPath: [.home])
        let noOpResult = noOpStore.execute(
            .whenCancelled(.pushAll([]), fallback: .push(.detail))
        )
        #expect(noOpResult == .success)
        #expect(noOpStore.state.path == [.home])
    }

    @Test("Store: middleware cancellation on primary runs fallback through middleware")
    @MainActor
    func storeMiddlewareCancelRunsFallback() {
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(middleware: blockCommandMiddleware { command in
                        if case .push(.detail) = command { return true }
                        return false
                    })
                ]
            )
        )

        // .push(.detail) is cancelled by middleware → .push(.home) runs.
        _ = store.execute(
            .whenCancelled(.push(.detail), fallback: .push(.home))
        )
        #expect(store.state.path == [.home])
    }

    @Test("Store: nested .whenCancelled unwraps left-to-right")
    @MainActor
    func storeNestedWhenCancelled() {
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(middleware: blockCommandMiddleware { command in
                        if case .push(.detail) = command { return true }
                        if case .push(.settings) = command { return true }
                        return false
                    })
                ]
            )
        )

        // detail → cancelled → settings → cancelled → home → succeeds
        _ = store.execute(
            .whenCancelled(
                .push(.detail),
                fallback: .whenCancelled(.push(.settings), fallback: .push(.home))
            )
        )
        #expect(store.state.path == [.home])
    }

    @Test("Store: nested failed choice restores before the outer fallback")
    @MainActor
    func storeNestedFailedChoiceUsesOuterFallbackSnapshot() {
        let store = NavigationStore<WCRoute>()

        let result = store.execute(
            .whenCancelled(
                .whenCancelled(
                    .pop,
                    fallback: .sequence([.push(.home), .popTo(.settings)])
                ),
                fallback: .push(.detail)
            )
        )

        #expect(result == .success)
        #expect(store.state.path == [.detail])
    }

    @Test("Store: fallback also gated by middleware surfaces as cancelled overall")
    @MainActor
    func storeFallbackAlsoCancelledSurfacesCancelled() {
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(middleware: blockCommandMiddleware { _ in true })
                ]
            )
        )
        let result = store.execute(
            .whenCancelled(.push(.detail), fallback: .push(.home))
        )
        // both cancelled → final result is cancelled
        if case .cancelled = result {
            #expect(store.state.path.isEmpty)
        } else {
            Issue.record("Expected .cancelled, got \(result)")
        }
    }

    @Test("Store: failed fallback rolls back its partial state")
    @MainActor
    func storeFailedFallbackRollsBack() {
        let store = NavigationStore<WCRoute>()

        let result = store.execute(
            .whenCancelled(
                .pop,
                fallback: .sequence([.push(.home), .popTo(.settings)])
            )
        )

        #expect(result == .multiple([.success, .routeNotFound(.settings)]))
        #expect(store.state.path.isEmpty)
    }

    @Test("Store: middleware-folded fallback failure rolls back engine success")
    @MainActor
    func storeFoldedFallbackFailureRollsBack() {
        var didExecuteCommands: [NavigationCommand<WCRoute>] = []
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(
                            willExecute: { command, _ in .proceed(command) },
                            didExecute: { command, result, _ in
                                didExecuteCommands.append(command)
                                if command == .push(.home) {
                                    return .cancelled(.custom("fallback rejected"))
                                }
                                return result
                            }
                        ),
                        debugName: "fold"
                    )
                ]
            )
        )

        let result = store.execute(
            .whenCancelled(.pop, fallback: .push(.home))
        )

        #expect(result == .cancelled(.custom("fallback rejected")))
        #expect(store.state.path.isEmpty)
        #expect(didExecuteCommands == [.pop, .push(.home)])
    }

    @Test("Batch: failed fallback restores its savepoint before the next command")
    @MainActor
    func batchFailedFallbackDoesNotLeakIntoNextCommand() {
        let store = NavigationStore<WCRoute>()

        let batch = store.executeBatch([
            .whenCancelled(
                .pop,
                fallback: .sequence([.push(.home), .popTo(.settings)])
            ),
            .push(.detail),
        ])

        #expect(
            batch.results == [
                .multiple([.success, .routeNotFound(.settings)]),
                .success,
            ]
        )
        #expect(
            batch.executedCommands == [
                .pop,
                .push(.home),
                .popTo(.settings),
                .push(.detail),
            ]
        )
        #expect(batch.stateAfter.path == [.detail])
        #expect(store.state.path == [.detail])
    }

    @Test("Batch: stopOnFailure observes failed fallback after rollback")
    @MainActor
    func batchStopOnFailedFallbackKeepsSnapshot() {
        var changeCount = 0
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    if case .changed = event { changeCount += 1 }
                }
            )
        )

        let batch = store.executeBatch(
            [
                .whenCancelled(
                    .pop,
                    fallback: .sequence([.push(.home), .popTo(.settings)])
                ),
                .push(.detail),
            ],
            stopOnFailure: true
        )

        #expect(batch.results == [.multiple([.success, .routeNotFound(.settings)])])
        #expect(batch.hasStoppedOnFailure)
        #expect(batch.stateAfter.path.isEmpty)
        #expect(store.state.path.isEmpty)
        #expect(changeCount == 0)
    }

    @Test("Store: didExecute-cancelled primary triggers fallback")
    @MainActor
    func storeDidExecuteCancelledPrimaryRunsFallback() {
        var didExecuteCommands: [NavigationCommand<WCRoute>] = []
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(
                            willExecute: { command, _ in .proceed(command) },
                            didExecute: { command, result, _ in
                                didExecuteCommands.append(command)
                                if case .push(.detail) = command {
                                    return .cancelled(.custom("post-execution cancel"))
                                }
                                return result
                            }
                        ),
                        debugName: "post"
                    )
                ]
            )
        )

        let result = store.execute(
            .whenCancelled(.push(.detail), fallback: .push(.home))
        )

        #expect(result == .success)
        #expect(store.state.path == [.home])
        #expect(didExecuteCommands == [.push(.detail), .push(.home)])
    }

    @Test("Store: didExecute-promoted success skips fallback")
    @MainActor
    func storeDidExecutePromotedSuccessSkipsFallback() {
        var didExecuteCommands: [NavigationCommand<WCRoute>] = []
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(
                            willExecute: { command, _ in .proceed(command) },
                            didExecute: { command, result, _ in
                                didExecuteCommands.append(command)
                                if case .pop = command {
                                    return .success
                                }
                                return result
                            }
                        ),
                        debugName: "post"
                    )
                ]
            )
        )

        let result = store.execute(
            .whenCancelled(.pop, fallback: .push(.home))
        )

        #expect(result == .success)
        #expect(store.state.path.isEmpty)
        #expect(didExecuteCommands == [.pop])
    }

    @Test("Store: rollback path emits only the committed change")
    @MainActor
    func storeRollbackNotifiesOnlyCommittedState() async throws {
        let observedChanges = Mutex<[(RouteStack<WCRoute>, RouteStack<WCRoute>)]>([])
        let observedEvents = Mutex<[NavigationEvent<WCRoute>]>([])
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    guard case .changed(let old, let new) = event else { return }
                    observedChanges.withLock { $0.append((old, new)) }
                }
            )
        )
        let stream = store.events
        let listener = Task {
            for await event in stream {
                observedEvents.withLock { $0.append(event) }
            }
        }

        _ = store.execute(
            .whenCancelled(
                .sequence([.push(.detail), .popTo(.settings)]),
                fallback: .push(.home)
            )
        )

        for _ in 0..<10 { await Task.yield() }
        listener.cancel()
        _ = await listener.result

        let changes = observedChanges.withLock { $0 }
        try #require(changes.count == 1)
        #expect(changes[0].0.path.isEmpty)
        #expect(changes[0].1.path == [.home])

        let changedEvents = observedEvents.withLock { events in
            events.compactMap { event -> (RouteStack<WCRoute>, RouteStack<WCRoute>)? in
                guard case .changed(let from, let to) = event else { return nil }
                return (from, to)
            }
        }
        try #require(changedEvents.count == 1)
        #expect(changedEvents[0].0.path.isEmpty)
        #expect(changedEvents[0].1.path == [.home])
    }

    @Test("Transaction: middleware-cancelled primary commits the fallback leg")
    @MainActor
    func transactionMiddlewareCancelledPrimaryUsesFallback() {
        var didExecuteCommands: [NavigationCommand<WCRoute>] = []
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(
                            willExecute: { command, _ in
                                if case .push(.detail) = command {
                                    return .cancel(.middleware(debugName: nil, command: command))
                                }
                                return .proceed(command)
                            },
                            didExecute: { command, result, _ in
                                didExecuteCommands.append(command)
                                return result
                            }
                        ),
                        debugName: "block"
                    )
                ]
            )
        )

        let transaction = store.executeTransaction([
            .whenCancelled(.push(.detail), fallback: .push(.home))
        ])

        #expect(transaction.isCommitted)
        #expect(transaction.failureIndex == nil)
        #expect(transaction.executedCommands == [.push(.home)])
        #expect(transaction.results == [.success])
        #expect(transaction.stateAfter.path == [.home])
        #expect(store.state.path == [.home])
        #expect(didExecuteCommands == [.push(.home)])
    }

    @Test("Transaction: engine-failed primary remains in attempted-command metadata")
    @MainActor
    func transactionEngineFailureRetainsBothAttemptedLegs() {
        let middleware = CleanupTrackingMiddleware { command, _ in
            .proceed(command)
        }
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(middleware),
                        debugName: "cleanup"
                    )
                ]
            )
        )

        let transaction = store.executeTransaction([
            .whenCancelled(.pop, fallback: .push(.home))
        ])

        #expect(transaction.isCommitted)
        #expect(transaction.executedCommands == [.pop, .push(.home)])
        #expect(transaction.results == [.success])
        #expect(transaction.stateAfter.path == [.home])
        #expect(middleware.discardedCommands == [.pop])
        #expect(middleware.didExecuteCommands == [.push(.home)])
    }

    @Test("Transaction: post-commit result folding does not reopen fallback choice")
    @MainActor
    func transactionPostCommitFoldCannotUndoCommit() {
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(
                            willExecute: { command, _ in .proceed(command) },
                            didExecute: { command, result, _ in
                                if command == .push(.home) {
                                    return .cancelled(.custom("post-commit fold"))
                                }
                                return result
                            }
                        ),
                        debugName: "fold"
                    )
                ]
            )
        )

        let transaction = store.executeTransaction([
            .whenCancelled(.pop, fallback: .push(.home))
        ])

        #expect(transaction.isCommitted)
        #expect(transaction.results == [.cancelled(.custom("post-commit fold"))])
        #expect(transaction.stateAfter.path == [.home])
        #expect(store.state.path == [.home])
    }

    @Test("Transaction: later failure discards both attempted choice legs")
    @MainActor
    func transactionOuterRollbackCleansFailedPrimaryAndSuccessfulFallback() {
        let middleware = CleanupTrackingMiddleware { command, _ in
            .proceed(command)
        }
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(middleware),
                        debugName: "cleanup"
                    )
                ]
            )
        )

        let transaction = store.executeTransaction([
            .whenCancelled(.pop, fallback: .push(.home)),
            .popTo(.settings),
        ])

        #expect(!transaction.isCommitted)
        #expect(transaction.failureIndex == 1)
        #expect(transaction.results == [.success, .routeNotFound(.settings)])
        #expect(transaction.executedCommands == [.pop, .push(.home), .popTo(.settings)])
        #expect(transaction.stateAfter.path.isEmpty)
        #expect(store.state.path.isEmpty)
        #expect(middleware.didExecuteCommands.isEmpty)
        #expect(middleware.discardedCommands == [.pop, .push(.home), .popTo(.settings)])
    }

    @Test("Transaction: discarded primary cleanup runs without surfacing public didExecute")
    @MainActor
    func transactionDiscardedPrimaryCleansUpWithoutDidExecute() {
        let middleware = CleanupTrackingMiddleware { command, _ in
            if case .push(.detail) = command {
                return .cancel(.middleware(debugName: nil, command: command))
            }
            return .proceed(command)
        }
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(middleware),
                        debugName: "cleanup"
                    )
                ]
            )
        )

        let transaction = store.executeTransaction([
            .whenCancelled(.push(.detail), fallback: .push(.home))
        ])

        #expect(transaction.isCommitted)
        #expect(transaction.executedCommands == [.push(.home)])
        #expect(transaction.results == [.success])
        #expect(middleware.discardedCommands == [.push(.detail)])
        #expect(middleware.didExecuteCommands == [.push(.home)])
    }

    @Test("Transaction: both failed legs restore the savepoint and clean every attempt")
    @MainActor
    func transactionFailedFallbackRestoresAndCleansEveryAttempt() {
        let middleware = CleanupTrackingMiddleware { command, _ in
            .proceed(command)
        }
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(middleware),
                        debugName: "cleanup"
                    )
                ]
            )
        )
        let primary: NavigationCommand<WCRoute> = .sequence([
            .push(.detail),
            .popTo(.settings),
        ])
        let fallback: NavigationCommand<WCRoute> = .sequence([
            .push(.home),
            .popTo(.settings),
        ])

        let transaction = store.executeTransaction([
            .whenCancelled(primary, fallback: fallback)
        ])

        #expect(!transaction.isCommitted)
        #expect(transaction.failureIndex == 0)
        #expect(transaction.results == [.multiple([.success, .routeNotFound(.settings)])])
        #expect(
            transaction.executedCommands == [
                .push(.detail),
                .popTo(.settings),
                .push(.home),
                .popTo(.settings),
            ]
        )
        #expect(transaction.stateAfter.path.isEmpty)
        #expect(store.state.path.isEmpty)
        #expect(middleware.didExecuteCommands.isEmpty)
        #expect(
            middleware.discardedCommands == [
                .push(.detail),
                .popTo(.settings),
                .push(.home),
                .popTo(.settings),
            ]
        )
    }

    @Test("Transaction: rollback cleans up discarded legs without public didExecute")
    @MainActor
    func transactionRollbackCleansUpDiscardedLegs() {
        let middleware = CleanupTrackingMiddleware { command, _ in
            .proceed(command)
        }
        let store = NavigationStore<WCRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    .init(
                        middleware: AnyNavigationMiddleware(middleware),
                        debugName: "cleanup"
                    )
                ]
            )
        )

        let transaction = store.executeTransaction([
            .push(.home),
            .popTo(.settings)
        ])

        #expect(!transaction.isCommitted)
        #expect(transaction.failureIndex == 1)
        #expect(transaction.results == [.success, .routeNotFound(.settings)])
        #expect(middleware.didExecuteCommands.isEmpty)
        #expect(middleware.discardedCommands == [.push(.home), .popTo(.settings)])
    }
}
