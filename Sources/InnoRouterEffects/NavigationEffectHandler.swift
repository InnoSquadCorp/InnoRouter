// MARK: - NavigationEffectHandler.swift
// InnoRouterEffects - Navigation Effect Handler
// Copyright © 2025 Inno Squad. All rights reserved.

import Foundation
import InnoRouterCore

/// App-boundary helper that executes navigation intents emitted from
/// non-SwiftUI features (InnoFlow effects, coordinator-owned async
/// pipelines) against a navigator while keeping the call sites on the
/// main actor.
public enum NavigationEffectHandlerEvent<R: Route>: Sendable, Equatable {
    case command(command: NavigationCommand<R>, result: NavigationResult<R>)
    case batch(commands: [NavigationCommand<R>], result: NavigationBatchResult<R>)
    case transaction(commands: [NavigationCommand<R>], result: NavigationTransactionResult<R>)
}

@MainActor
public final class NavigationEffectHandler<R: Route> {
    private let executeCommand: @MainActor (NavigationCommand<R>) -> NavigationResult<R>
    private let executeBatchCommands: @MainActor ([NavigationCommand<R>], Bool) -> NavigationBatchResult<R>
    private let executeTransactionCommands: @MainActor ([NavigationCommand<R>]) -> NavigationTransactionResult<R>
    private let readState: @MainActor () -> RouteStack<R>
    private let broadcaster: EventBroadcaster<NavigationEffectHandlerEvent<R>>

    public var events: AsyncStream<NavigationEffectHandlerEvent<R>> {
        broadcaster.stream()
    }

    public init<N: Navigator & NavigationBatchExecutor & NavigationTransactionExecutor>(
        navigator: N
    ) where N.RouteType == R {
        self.executeCommand = { command in
            navigator.execute(command)
        }
        self.executeBatchCommands = { commands, stopOnFailure in
            navigator.executeBatch(commands, stopOnFailure: stopOnFailure)
        }
        self.executeTransactionCommands = { commands in
            navigator.executeTransaction(commands)
        }
        self.readState = {
            navigator.state
        }
        self.broadcaster = EventBroadcaster()
    }

    @discardableResult
    public func execute(_ command: NavigationCommand<R>) -> NavigationResult<R> {
        let result = executeCommand(command)
        broadcaster.broadcast(.command(command: command, result: result))
        return result
    }

    @discardableResult
    public func execute(
        _ commands: [NavigationCommand<R>],
        stopOnFailure: Bool = false
    ) -> NavigationBatchResult<R> {
        let batchResult = executeBatchCommands(commands, stopOnFailure)
        broadcaster.broadcast(.batch(commands: commands, result: batchResult))
        return batchResult
    }

    @discardableResult
    public func executeTransaction(
        _ commands: [NavigationCommand<R>]
    ) -> NavigationTransactionResult<R> {
        let transactionResult = executeTransactionCommands(commands)
        broadcaster.broadcast(.transaction(commands: commands, result: transactionResult))
        return transactionResult
    }

    var state: RouteStack<R> {
        readState()
    }

    @discardableResult
    public func executeIf(
        _ shouldExecute: @escaping @Sendable () -> Bool,
        command: NavigationCommand<R>
    ) -> NavigationResult<R> {
        guard shouldExecute() else {
            let result: NavigationResult<R> = .cancelled(.conditionFailed)
            broadcaster.broadcast(.command(command: command, result: result))
            return result
        }
        return execute(command)
    }

    @discardableResult
    public func executeGuarded(
        _ command: NavigationCommand<R>,
        prepare: @escaping @MainActor @Sendable (NavigationCommand<R>) async -> NavigationInterception<R>
    ) async -> NavigationResult<R> {
        switch await prepare(command) {
        case .proceed(let updatedCommand):
            guard updatedCommand.canExecute(on: readState()) else {
                let result: NavigationResult<R> = .cancelled(.staleAfterPrepare(command: updatedCommand))
                broadcaster.broadcast(.command(command: updatedCommand, result: result))
                return result
            }
            return execute(updatedCommand)
        case .cancel(let reason):
            let result: NavigationResult<R> = .cancelled(reason)
            broadcaster.broadcast(.command(command: command, result: result))
            return result
        }
    }
}

public protocol NavigationEffect {
    associatedtype RouteType: Route
    var navigationCommand: NavigationCommand<RouteType>? { get }
    static func navigation(_ command: NavigationCommand<RouteType>) -> Self
}

public extension NavigationEffectHandler {
    @discardableResult
    func handle<E: NavigationEffect>(_ effect: E) -> NavigationResult<R>? where E.RouteType == R {
        guard let command = effect.navigationCommand else { return nil }
        return execute(command)
    }
}
