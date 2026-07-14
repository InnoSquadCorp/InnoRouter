// MARK: - NavigationTestStoreTests.swift
// InnoRouterTestingTests - NavigationTestStore behavior
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterTesting

private enum NavRoute: Route {
    case home
    case detail
    case settings
}

@MainActor
private func noopMiddleware() -> AnyNavigationMiddleware<NavRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in .proceed(command) })
}

@Suite("NavigationTestStore Tests")
struct NavigationTestStoreTests {

    @Test("send(.go) emits a .changed event in FIFO order")
    @MainActor
    func sendGoEmitsChanged() {
        let store = NavigationTestStore<NavRoute>()

        store.send(.go(.home))

        store.receiveChange { old, new in
            old.path.isEmpty && new.path == [.home]
        }
        store.finish()
    }

    @Test("executeBatch emits a single coalesced .changed then .batchExecuted")
    @MainActor
    func executeBatchEmitsCoalescedChangeThenBatch() {
        let store = NavigationTestStore<NavRoute>()

        let result = store.executeBatch([.push(.home), .push(.detail)])

        #expect(result.isSuccess)
        // NavigationStore coalesces per-step changes into one final .changed,
        // then emits .batchExecuted. TestStore preserves that order.
        store.receiveChange { _, new in new.path == [.home, .detail] }
        store.receiveBatch { $0.executedCommands.count == 2 && $0.isSuccess }
        store.finish()
    }

    @Test("executeTransaction commits — emits .changed and .transactionExecuted in order")
    @MainActor
    func executeTransactionCommits() {
        let store = NavigationTestStore<NavRoute>()

        _ = store.executeTransaction([.push(.home), .push(.detail)])

        store.receiveChange { _, new in new.path == [.home, .detail] }
        store.receiveTransaction { $0.isCommitted && $0.stateAfter.path == [.home, .detail] }
        store.finish()
    }

    @Test("middleware mutation emits .middlewareMutation via public observer")
    @MainActor
    func middlewareMutationEmitted() {
        let store = NavigationTestStore<NavRoute>()

        _ = store.store.addMiddleware(noopMiddleware(), debugName: "obs")

        store.receiveMiddlewareMutation(action: .added)
        store.finish()
    }

    @Test("Preserves user-supplied onEvent observer (chains, does not replace)")
    @MainActor
    func userChangedEventObserverPreserved() {
        let captured = Mutex<[[NavRoute]]>([])
        let store = NavigationTestStore<NavRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    guard case .changed(_, let new) = event else { return }
                    captured.withLock { $0.append(new.path) }
                }
            )
        )

        store.send(.go(.home))
        store.receiveChange()

        #expect(captured.withLock { $0 } == [[.home]])
    }

    @Test("receive with equality on unmatched event records an issue")
    @MainActor
    func receiveEqualityMismatchRecordsIssue() {
        withKnownIssue {
            let store = NavigationTestStore<NavRoute>()
            store.send(.go(.home))
            // Expect a batch where there is only a .changed — must fail.
            store.receiveBatch()
            store.skipReceivedEvents()
            store.finish()
        }
    }

    @Test("receive when queue is empty records an issue")
    @MainActor
    func receiveOnEmptyQueueRecordsIssue() {
        withKnownIssue {
            let store = NavigationTestStore<NavRoute>()
            // No events — this must fail.
            store.receiveChange()
            store.finish()
        }
    }
}
