import InnoRouterCore

struct NavigationExecutionOutcome<R: Route> {
    let executedCommands: [NavigationCommand<R>]
    let result: NavigationResult<R>
    let observationEvents: [NavigationEvent<R>]
}

/// Applies command semantics and balances middleware callbacks without owning
/// the observable store state or its public event-delivery policy.
@MainActor
final class NavigationExecutionCoordinator<R: Route> {
    private let middlewareRegistry: NavigationMiddlewareRegistry<R>
    private let engine = NavigationEngine<R>()

    init(middlewareRegistry: NavigationMiddlewareRegistry<R>) {
        self.middlewareRegistry = middlewareRegistry
    }

    func execute(
        _ command: NavigationCommand<R>,
        state currentState: inout RouteStack<R>,
        shouldNotifyOnChange: Bool
    ) -> NavigationExecutionOutcome<R> {
        switch command {
        case .sequence(let commands):
            let outcomes = commands.map {
                execute($0, state: &currentState, shouldNotifyOnChange: shouldNotifyOnChange)
            }
            return NavigationExecutionOutcome(
                executedCommands: outcomes.flatMap(\.executedCommands),
                result: .multiple(outcomes.map(\.result)),
                observationEvents: outcomes.flatMap(\.observationEvents)
            )

        case .whenCancelled(let primary, let fallback):
            let snapshot = currentState
            var primaryState = snapshot
            let primaryOutcome = execute(
                primary,
                state: &primaryState,
                shouldNotifyOnChange: false
            )
            if primaryOutcome.result.isSuccess {
                currentState = primaryState
                return NavigationExecutionOutcome(
                    executedCommands: primaryOutcome.executedCommands,
                    result: primaryOutcome.result,
                    observationEvents: Self.changeEvents(
                        from: snapshot,
                        to: currentState,
                        shouldNotify: shouldNotifyOnChange
                    )
                )
            }

            var fallbackState = snapshot
            let fallbackOutcome = execute(
                fallback,
                state: &fallbackState,
                shouldNotifyOnChange: false
            )
            currentState = fallbackOutcome.result.isSuccess ? fallbackState : snapshot
            return NavigationExecutionOutcome(
                executedCommands: primaryOutcome.executedCommands + fallbackOutcome.executedCommands,
                result: fallbackOutcome.result,
                observationEvents: Self.changeEvents(
                    from: snapshot,
                    to: currentState,
                    shouldNotify: shouldNotifyOnChange
                )
            )

        default:
            return executeLeaf(
                command,
                state: &currentState,
                shouldNotifyOnChange: shouldNotifyOnChange
            )
        }
    }

    func preview(
        _ command: NavigationCommand<R>,
        from stateBefore: RouteStack<R>
    ) -> NavigationExecutionJournal<R> {
        NavigationExecutionJournal.preview(
            command,
            from: stateBefore,
            middlewareRegistry: middlewareRegistry,
            engine: engine
        )
    }

    func planTransaction(
        _ command: NavigationCommand<R>,
        state: inout RouteStack<R>
    ) -> NavigationExecutionJournal<R> {
        NavigationExecutionJournal.planTransaction(
            command,
            state: &state,
            middlewareRegistry: middlewareRegistry,
            engine: engine
        )
    }

    func finalizePreview(
        _ preview: NavigationExecutionJournal<R>
    ) -> NavigationResult<R> {
        preview.finalizePreview(using: middlewareRegistry)
    }

    func finalizeCommittedTransaction(
        _ journal: NavigationExecutionJournal<R>
    ) -> NavigationResult<R> {
        journal.finalizeCommittedTransaction(using: middlewareRegistry)
    }

    func discardExecuted(_ journal: NavigationExecutionJournal<R>) {
        journal.discardExecuted(using: middlewareRegistry)
    }

    private func executeLeaf(
        _ command: NavigationCommand<R>,
        state currentState: inout RouteStack<R>,
        shouldNotifyOnChange: Bool
    ) -> NavigationExecutionOutcome<R> {
        let stateBefore = currentState
        let interceptionOutcome = middlewareRegistry.intercept(command, state: stateBefore)
        switch interceptionOutcome.interception {
        case .cancel(let reason):
            return finishExecution(
                command: interceptionOutcome.command,
                executedCommands: [],
                result: .cancelled(reason),
                participants: interceptionOutcome.participants,
                stateBefore: stateBefore,
                currentState: &currentState,
                shouldNotifyOnChange: shouldNotifyOnChange
            )

        case .proceed(let commandToExecute):
            let result = engine.apply(commandToExecute, to: &currentState)
            return finishExecution(
                command: commandToExecute,
                executedCommands: [commandToExecute],
                result: result,
                participants: interceptionOutcome.participants,
                stateBefore: stateBefore,
                currentState: &currentState,
                shouldNotifyOnChange: shouldNotifyOnChange
            )
        }
    }

    private func finishExecution(
        command: NavigationCommand<R>,
        executedCommands: [NavigationCommand<R>],
        result: NavigationResult<R>,
        participants: [AnyNavigationMiddleware<R>],
        stateBefore: RouteStack<R>,
        currentState: inout RouteStack<R>,
        shouldNotifyOnChange: Bool
    ) -> NavigationExecutionOutcome<R> {
        let finalResult = middlewareRegistry.didExecute(
            command,
            result: result,
            state: currentState,
            participants: participants
        )

        return NavigationExecutionOutcome(
            executedCommands: executedCommands,
            result: finalResult,
            observationEvents: Self.changeEvents(
                from: stateBefore,
                to: currentState,
                shouldNotify: shouldNotifyOnChange
            )
        )
    }

    private static func changeEvents(
        from oldState: RouteStack<R>,
        to newState: RouteStack<R>,
        shouldNotify: Bool
    ) -> [NavigationEvent<R>] {
        guard shouldNotify, newState != oldState else { return [] }
        return [.changed(from: oldState, to: newState)]
    }
}
