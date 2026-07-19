// MARK: - NavigationStoreReentrancyTests.swift

import InnoRouter
import Testing

@MainActor
private final class NavigationStoreReentrancyMiddleware: NavigationMiddleware {
    enum Callback {
        case willExecute
        case didExecute
    }

    enum Attempt {
        case execute
        case batch
        case transaction
        case send
        case projectBackByOne
    }

    typealias RouteType = TestRoute

    weak var store: NavigationStore<TestRoute>?
    let callback: Callback
    let attempt: Attempt
    private var hasAttempted = false

    private(set) var singleResult: NavigationResult<TestRoute>?
    private(set) var batchResult: NavigationBatchResult<TestRoute>?
    private(set) var transactionResult: NavigationTransactionResult<TestRoute>?
    private(set) var projectedCommands: [NavigationCommand<TestRoute>]?

    init(callback: Callback, attempt: Attempt) {
        self.callback = callback
        self.attempt = attempt
    }

    func willExecute(
        _ command: NavigationCommand<TestRoute>,
        state: RouteStack<TestRoute>
    ) -> NavigationInterception<TestRoute> {
        if callback == .willExecute {
            attemptReentry()
        }
        return .proceed(command)
    }

    func didExecute(
        _ command: NavigationCommand<TestRoute>,
        result: NavigationResult<TestRoute>,
        state: RouteStack<TestRoute>
    ) -> NavigationResult<TestRoute> {
        if callback == .didExecute {
            attemptReentry()
        }
        return result
    }

    private func attemptReentry() {
        guard !hasAttempted, let store else { return }
        hasAttempted = true

        switch attempt {
        case .execute:
            singleResult = store.execute(.push(.settings))
        case .batch:
            batchResult = store.executeBatch([
                .push(.settings),
                .push(.detail(id: "nested")),
            ])
        case .transaction:
            transactionResult = store.executeTransaction([
                .push(.settings),
                .push(.detail(id: "nested")),
            ])
        case .send:
            store.send(.go(.settings))
        case .projectBackByOne:
            projectedCommands = store.commands(for: .backBy(1))
        }
    }
}

@Suite("NavigationStore Reentrancy Tests")
struct NavigationStoreReentrancyTests {
    @Test("willExecute rejects same-store execute without losing the outer command")
    @MainActor
    func willExecuteRejectsSingleExecution() {
        let middleware = NavigationStoreReentrancyMiddleware(
            callback: .willExecute,
            attempt: .execute
        )
        let store = makeStore(middleware)

        let outerResult = store.execute(.push(.home))

        #expect(outerResult == .success)
        #expect(isReentrantRejection(middleware.singleResult))
        #expect(store.state.path == [.home])
    }

    @Test("didExecute rejects same-store execute after the outer state is planned")
    @MainActor
    func didExecuteRejectsSingleExecution() {
        let middleware = NavigationStoreReentrancyMiddleware(
            callback: .didExecute,
            attempt: .execute
        )
        let store = makeStore(middleware)

        let outerResult = store.execute(.push(.home))

        #expect(outerResult == .success)
        #expect(isReentrantRejection(middleware.singleResult))
        #expect(store.state.path == [.home])
    }

    @Test("willExecute rejects every command in a reentrant batch")
    @MainActor
    func willExecuteRejectsBatchExecution() throws {
        let middleware = NavigationStoreReentrancyMiddleware(
            callback: .willExecute,
            attempt: .batch
        )
        let store = makeStore(middleware)

        #expect(store.execute(.push(.home)) == .success)

        let result = try #require(middleware.batchResult)
        #expect(result.requestedCommands.count == 2)
        #expect(result.executedCommands.isEmpty)
        #expect(result.results.count == 2)
        #expect(result.results.allSatisfy(isReentrantRejection))
        #expect(result.stateBefore == result.stateAfter)
        #expect(store.state.path == [.home])
    }

    @Test("willExecute rejects a reentrant transaction at its first command")
    @MainActor
    func willExecuteRejectsTransactionExecution() throws {
        let middleware = NavigationStoreReentrancyMiddleware(
            callback: .willExecute,
            attempt: .transaction
        )
        let store = makeStore(middleware)

        #expect(store.execute(.push(.home)) == .success)

        let result = try #require(middleware.transactionResult)
        #expect(result.requestedCommands.count == 2)
        #expect(result.executedCommands.isEmpty)
        #expect(result.results.count == 1)
        #expect(isReentrantRejection(result.results.first))
        #expect(result.failureIndex == 0)
        #expect(result.isCommitted == false)
        #expect(result.stateBefore == result.stateAfter)
        #expect(store.state.path == [.home])
    }

    @Test("willExecute drops a reentrant void intent without mutating state")
    @MainActor
    func willExecuteRejectsIntentSend() {
        let middleware = NavigationStoreReentrancyMiddleware(
            callback: .willExecute,
            attempt: .send
        )
        let store = makeStore(middleware)

        #expect(store.execute(.push(.home)) == .success)
        #expect(store.state.path == [.home])
    }

    @Test("middleware command projection uses the callback state snapshot")
    @MainActor
    func commandProjectionUsesCallbackState() {
        let middleware = NavigationStoreReentrancyMiddleware(
            callback: .didExecute,
            attempt: .projectBackByOne
        )
        let store = makeStore(middleware)

        #expect(store.execute(.push(.home)) == .success)
        #expect(middleware.projectedCommands == [.popToRoot])
        #expect(store.state.path == [.home])
    }

    @MainActor
    private func makeStore(
        _ middleware: NavigationStoreReentrancyMiddleware
    ) -> NavigationStore<TestRoute> {
        let store = NavigationStore<TestRoute>(
            configuration: NavigationStoreConfiguration(
                middlewares: [
                    NavigationMiddlewareRegistration(
                        middleware: AnyNavigationMiddleware(middleware),
                        debugName: "reentrant-probe"
                    )
                ]
            )
        )
        middleware.store = store
        return store
    }

    private func isReentrantRejection(
        _ result: NavigationResult<TestRoute>?
    ) -> Bool {
        guard case .cancelled(.custom(let message)) = result else {
            return false
        }
        return message.contains("cannot synchronously re-enter")
    }
}
