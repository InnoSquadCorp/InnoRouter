// MARK: - AsyncNavigationMiddlewareExecutor.swift
// InnoRouterSwiftUI - executor that runs async navigation
// middleware around the synchronous engine.
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// Executor that layers ``AsyncNavigationMiddleware`` around a
/// ``NavigationStore``'s synchronous engine.
///
/// `NavigationStore.execute(_:)` keeps its synchronous, typed shape
/// — async middleware run only when commands flow through this
/// executor. The executor:
///
/// 1. Runs every registered async `willExecute(_:state:)` in
///    insertion order, threading rewritten commands forward.
/// 2. Stops the chain on the first
///    ``NavigationInterception/cancel(_:)`` and surfaces the
///    typed cancellation as the final result.
/// 3. Revalidates the resulting command against the latest store
///    state after every async suspension has completed.
/// 4. Calls `store.execute(_:)` synchronously with the resulting
///    command — synchronous middleware on the store still runs
///    inside that call.
/// 5. Runs every registered async `didExecute` in reverse order so
///    fold rules compose intuitively.
///
/// Adopters use this for policies that genuinely need a
/// suspension boundary at the routing layer (token refresh,
/// remote A/B resolution, async permission probe). Synchronous
/// policies should keep using ``NavigationMiddleware``.
@MainActor
public final class AsyncNavigationMiddlewareExecutor<R: Route> {

    private weak var store: NavigationStore<R>?
    private var middleware: [any AsyncNavigationMiddleware<R>] = []

    public init(store: NavigationStore<R>) {
        self.store = store
    }

    /// Append an async middleware to the executor. The middleware
    /// runs in insertion order on `willExecute` and reverse order
    /// on `didExecute`.
    public func add(_ middleware: any AsyncNavigationMiddleware<R>) {
        self.middleware.append(middleware)
    }

    /// Run async middleware around a single synchronous command.
    ///
    /// Returns the final `NavigationResult<R>` — either the
    /// engine's result possibly folded by `didExecute`, or a
    /// `.cancelled(_:)` value if any pre-execution stage cancelled.
    @discardableResult
    public func execute(_ command: NavigationCommand<R>) async -> NavigationResult<R> {
        guard let store else {
            return .cancelled(.custom("AsyncNavigationMiddlewareExecutor lost its store"))
        }

        var current = command
        for stage in middleware {
            switch await stage.willExecute(current, state: store.state) {
            case .proceed(let rewritten):
                current = rewritten
            case .cancel(let reason):
                return .cancelled(reason)
            }
        }

        guard current.canExecute(on: store.state) else {
            return .cancelled(.staleAfterPrepare(command: current))
        }

        var result = store.execute(current)

        for stage in middleware.reversed() {
            result = await stage.didExecute(current, result: result, state: store.state)
        }

        return result
    }
}
