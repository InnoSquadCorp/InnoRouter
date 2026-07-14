// MARK: - NavigationMiddlewareAlgebraPropertyTests.swift
// InnoRouterTests - property coverage for navigation middleware algebra
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouterCore
import InnoRouter
import InnoRouterSwiftUI

@MainActor
private final class PropertyNavigationTrackerMiddleware:
    NavigationMiddleware,
    NavigationMiddlewareDiscardCleanup
{
    typealias RouteType = PropertyRoute

    private(set) var didExecuteCommands: [NavigationCommand<PropertyRoute>] = []
    private(set) var discardedCommands: [NavigationCommand<PropertyRoute>] = []

    func willExecute(
        _ command: NavigationCommand<PropertyRoute>,
        state: RouteStack<PropertyRoute>
    ) -> NavigationInterception<PropertyRoute> {
        .proceed(command)
    }

    func didExecute(
        _ command: NavigationCommand<PropertyRoute>,
        result: NavigationResult<PropertyRoute>,
        state: RouteStack<PropertyRoute>
    ) -> NavigationResult<PropertyRoute> {
        didExecuteCommands.append(command)
        return result
    }

    func discardExecution(
        _ command: NavigationCommand<PropertyRoute>,
        result: NavigationResult<PropertyRoute>,
        state: RouteStack<PropertyRoute>
    ) {
        discardedCommands.append(command)
    }

    func didExecuteMark() -> Int {
        didExecuteCommands.count
    }

    func discardedMark() -> Int {
        discardedCommands.count
    }

    func didExecuteCommands(since index: Int) -> [NavigationCommand<PropertyRoute>] {
        Array(didExecuteCommands.dropFirst(index))
    }

    func discardedCommands(since index: Int) -> [NavigationCommand<PropertyRoute>] {
        Array(discardedCommands.dropFirst(index))
    }
}

@Suite("Navigation middleware algebra property-based tests")
struct NavigationMiddlewareAlgebraPropertyTests {

    @Test(
        "Composite navigation commands obey multi-middleware execute algebra",
        arguments: Array(0..<48)
    )
    @MainActor
    func compositeExecuteMatchesReferenceModel(seed: Int) {
        var rng = PropertyPBTGenerator(seed: seed)
        let policy = PropertyMiddlewareChainPolicy(seed: seed)
        let tracker = PropertyNavigationTrackerMiddleware()
        let store = NavigationStore<PropertyRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [.init(middleware: AnyNavigationMiddleware(tracker), debugName: "tracker")]
                    + policy.navigationRegistrations()
            )
        )

        for step in 0..<20 {
            let command = rng.nextCompositeNavigationCommand(maxDepth: 2)
            let initialState = store.state
            let didExecuteMark = tracker.didExecuteMark()
            let discardMark = tracker.discardedMark()

            let expected = modelNavigationExecute(
                command,
                initialState: initialState,
                middlewarePolicy: policy
            )
            let actual = store.execute(command)

            if actual != expected.result {
                Issue.record(
                    "seed \(seed) step \(step): execute result mismatch for \(command). expected \(expected.result), got \(actual)"
                )
            }

            if store.state != expected.stateAfter {
                Issue.record(
                    "seed \(seed) step \(step): execute state mismatch for \(command). expected \(expected.stateAfter.path), got \(store.state.path)"
                )
            }

            if tracker.didExecuteCommands(since: didExecuteMark) != expected.didExecuteCommands {
                Issue.record(
                    "seed \(seed) step \(step): didExecute sequence mismatch for \(command). expected \(expected.didExecuteCommands), got \(tracker.didExecuteCommands(since: didExecuteMark))"
                )
            }

            if !tracker.discardedCommands(since: discardMark).isEmpty {
                Issue.record(
                    "seed \(seed) step \(step): execute path unexpectedly triggered discard cleanup for \(command): \(tracker.discardedCommands(since: discardMark))"
                )
            }
        }
    }

    @Test(
        "Leaf-command transactions keep commit-only didExecute and discard cleanup aligned under middleware chains",
        arguments: Array(0..<48)
    )
    @MainActor
    func transactionMatchesReferenceModel(seed: Int) {
        var rng = PropertyPBTGenerator(seed: seed)
        let policy = PropertyMiddlewareChainPolicy(seed: seed)
        let tracker = PropertyNavigationTrackerMiddleware()
        let store = NavigationStore<PropertyRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [.init(middleware: AnyNavigationMiddleware(tracker), debugName: "tracker")]
                    + policy.navigationRegistrations()
            )
        )

        for step in 0..<18 {
            let commands = rng.nextTransactionCommands()
            let initialState = store.state
            let didExecuteMark = tracker.didExecuteMark()
            let discardMark = tracker.discardedMark()

            let expected = modelNavigationTransaction(
                commands,
                initialState: initialState,
                middlewarePolicy: policy
            )
            let actual = store.executeTransaction(commands)

            if actual != expected.transaction {
                Issue.record(
                    "seed \(seed) step \(step): transaction mismatch for \(commands). expected \(expected.transaction), got \(actual)"
                )
            }

            if tracker.didExecuteCommands(since: didExecuteMark) != expected.didExecuteCommands {
                Issue.record(
                    "seed \(seed) step \(step): transaction didExecute mismatch for \(commands). expected \(expected.didExecuteCommands), got \(tracker.didExecuteCommands(since: didExecuteMark))"
                )
            }

            if tracker.discardedCommands(since: discardMark) != expected.discardedCommands {
                Issue.record(
                    "seed \(seed) step \(step): transaction discard mismatch for \(commands). expected \(expected.discardedCommands), got \(tracker.discardedCommands(since: discardMark))"
                )
            }
        }
    }
}
