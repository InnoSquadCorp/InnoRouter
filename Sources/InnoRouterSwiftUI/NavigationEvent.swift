// MARK: - NavigationEvent.swift
// InnoRouterSwiftUI - unified observable event for NavigationStore
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

/// A single event produced by a `NavigationStore` observation surface.
///
/// These cases form the complete public `NavigationStore` observation
/// surface. `NavigationStore.events` exposes them as a single
/// `AsyncStream<NavigationEvent<R>>` so analytics, logging, and debugging
/// pipelines can consume the same values delivered synchronously through
/// `NavigationStoreConfiguration.onEvent`.
///
/// Test harnesses (`InnoRouterTesting`) reuse this type directly — the
/// legacy `NavigationTestEvent<R>` is preserved as a typealias for
/// source compatibility.
public enum NavigationEvent<R: Route>: Sendable, Equatable {
    /// The navigation stack changed through a command or external path
    /// binding update.
    case changed(from: RouteStack<R>, to: RouteStack<R>)

    /// A batch execution completed.
    case batchExecuted(NavigationBatchResult<R>)

    /// A transaction execution committed or did not commit.
    case transactionExecuted(NavigationTransactionResult<R>)

    /// A middleware registry mutation succeeded.
    case middlewareMutation(MiddlewareMutationEvent<R>)

    /// The path mismatch policy resolved a reconciliation divergence.
    case pathMismatch(NavigationPathMismatchEvent<R>)
}

extension NavigationEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .changed(let from, let to):
            return ".changed(from: \(from.path), to: \(to.path))"
        case .batchExecuted(let result):
            return ".batchExecuted(attempted: \(result.executedCommands.count), isSuccess: \(result.isSuccess))"
        case .transactionExecuted(let result):
            return ".transactionExecuted(isCommitted: \(result.isCommitted))"
        case .middlewareMutation(let event):
            return ".middlewareMutation(action: \(event.action.rawValue))"
        case .pathMismatch(let event):
            return ".pathMismatch(policy: \(event.policy.rawValue))"
        }
    }
}
