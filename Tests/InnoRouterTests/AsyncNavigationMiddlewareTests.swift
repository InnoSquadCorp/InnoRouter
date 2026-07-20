// MARK: - AsyncNavigationMiddlewareTests.swift
// InnoRouterTests - opt-in async middleware executor.
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum AsyncRoute: Route {
    case home
    case detail(Int)
}

// MARK: - Fixtures

private struct PassthroughAsyncMiddleware: AsyncNavigationMiddleware {
    typealias RouteType = AsyncRoute

    func willExecute(
        _ command: NavigationCommand<AsyncRoute>,
        state: RouteStack<AsyncRoute>
    ) async -> NavigationInterception<AsyncRoute> {
        .proceed(command)
    }
}

private struct CancellingAsyncMiddleware: AsyncNavigationMiddleware {
    typealias RouteType = AsyncRoute
    let reasonText: String

    func willExecute(
        _ command: NavigationCommand<AsyncRoute>,
        state: RouteStack<AsyncRoute>
    ) async -> NavigationInterception<AsyncRoute> {
        .cancel(.custom(reasonText))
    }
}

private struct RewritingAsyncMiddleware: AsyncNavigationMiddleware {
    typealias RouteType = AsyncRoute
    let replacement: NavigationCommand<AsyncRoute>

    func willExecute(
        _ command: NavigationCommand<AsyncRoute>,
        state: RouteStack<AsyncRoute>
    ) async -> NavigationInterception<AsyncRoute> {
        .proceed(replacement)
    }
}

private actor AsyncMiddlewareGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            didEnter = true

            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct SuspendingAsyncMiddleware: AsyncNavigationMiddleware {
    typealias RouteType = AsyncRoute
    let gate: AsyncMiddlewareGate

    func willExecute(
        _ command: NavigationCommand<AsyncRoute>,
        state: RouteStack<AsyncRoute>
    ) async -> NavigationInterception<AsyncRoute> {
        await gate.suspend()
        return .proceed(command)
    }
}

@Suite("AsyncNavigationMiddlewareExecutor")
@MainActor
struct AsyncNavigationMiddlewareTests {

    // MARK: - Passthrough

    @Test("a passthrough async middleware lets the command reach the engine unchanged")
    func passthrough_executesEngine() async {
        let store = NavigationStore<AsyncRoute>()
        let executor = AsyncNavigationMiddlewareExecutor(store: store)
        executor.add(PassthroughAsyncMiddleware())

        let result = await executor.execute(.push(.home))

        #expect(result.isSuccess)
        #expect(store.state.path == [.home])
    }

    // MARK: - Cancellation

    @Test("a cancelling async middleware short-circuits with a typed reason")
    func cancellingMiddleware_shortCircuits() async {
        let store = NavigationStore<AsyncRoute>()
        let executor = AsyncNavigationMiddlewareExecutor(store: store)
        executor.add(CancellingAsyncMiddleware(reasonText: "AB-test guard"))

        let result = await executor.execute(.push(.home))

        guard case .cancelled(.custom(let reason)) = result else {
            Issue.record("Expected .cancelled(.custom), got \(result)")
            return
        }
        #expect(reason == "AB-test guard")
        #expect(store.state.path.isEmpty)
    }

    // MARK: - Rewriting

    @Test("a rewriting async middleware replaces the command before the engine runs")
    func rewritingMiddleware_swapsCommand() async {
        let store = NavigationStore<AsyncRoute>()
        let executor = AsyncNavigationMiddlewareExecutor(store: store)
        executor.add(RewritingAsyncMiddleware(replacement: .push(.detail(42))))

        let result = await executor.execute(.push(.home))

        #expect(result.isSuccess)
        #expect(store.state.path == [.detail(42)])
    }

    @Test("a command invalidated while async middleware is suspended is rejected as stale")
    func suspendedMiddleware_revalidatesBeforeExecution() async {
        let store = NavigationStore<AsyncRoute>()
        _ = store.execute(.push(.home))

        let gate = AsyncMiddlewareGate()
        let executor = AsyncNavigationMiddlewareExecutor(store: store)
        executor.add(SuspendingAsyncMiddleware(gate: gate))

        let execution = Task { @MainActor in
            await executor.execute(.pop)
        }

        await gate.waitUntilEntered()
        _ = store.execute(.pop)
        await gate.release()

        let result = await execution.value
        #expect(result == .cancelled(.staleAfterPrepare(command: .pop)))
        #expect(store.state.path.isEmpty)
    }

    // MARK: - Synchronous engine path is untouched

    @Test("store.execute(_:) ignores async middleware and runs the synchronous engine directly")
    func syncExecute_bypassesAsyncStack() async {
        let store = NavigationStore<AsyncRoute>()
        let executor = AsyncNavigationMiddlewareExecutor(store: store)
        executor.add(CancellingAsyncMiddleware(reasonText: "ignored"))

        // Bypass the executor — call the store's synchronous API
        // directly. The async middleware must not see this call.
        let result = store.execute(.push(.home))

        #expect(result.isSuccess)
        #expect(store.state.path == [.home])
    }
}
