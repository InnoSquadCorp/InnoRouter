import InnoRouterCore

@MainActor
struct NavigationExecutionJournal<R: Route> {
    enum Kind {
        case leaf
        case sequence
        case whenCancelled
    }

    enum LeafDisposition {
        case publicDidExecute
        case discardCleanup
        case wrapperOnly
    }

    let kind: Kind
    let requestedCommand: NavigationCommand<R>
    let effectiveCommand: NavigationCommand<R>?
    let participants: [AnyNavigationMiddleware<R>]?
    let result: NavigationResult<R>
    let stateBefore: RouteStack<R>
    let stateAfter: RouteStack<R>
    let children: [NavigationExecutionJournal<R>]
    let leafDisposition: LeafDisposition
    let executedCommands: [NavigationCommand<R>]

    static func preview(
        _ command: NavigationCommand<R>,
        from stateBefore: RouteStack<R>,
        middlewareRegistry: NavigationMiddlewareRegistry<R>,
        engine: NavigationEngine<R>
    ) -> Self {
        switch command {
        case .sequence, .whenCancelled:
            preconditionFailure("FlowStore preview does not support composite navigation commands.")

        default:
            var shadowState = stateBefore
            return planLeaf(
                command,
                state: &shadowState,
                middlewareRegistry: middlewareRegistry,
                engine: engine,
                disposition: .publicDidExecute
            )
        }
    }

    static func planTransaction(
        _ command: NavigationCommand<R>,
        state currentState: inout RouteStack<R>,
        middlewareRegistry: NavigationMiddlewareRegistry<R>,
        engine: NavigationEngine<R>
    ) -> Self {
        switch command {
        case .sequence(let commands):
            let stateBefore = currentState
            var children: [Self] = []
            var executedCommands: [NavigationCommand<R>] = []

            for nestedCommand in commands {
                let child = planTransaction(
                    nestedCommand,
                    state: &currentState,
                    middlewareRegistry: middlewareRegistry,
                    engine: engine
                )
                children.append(child)
                executedCommands.append(contentsOf: child.executedCommands)
                if !child.result.isSuccess {
                    return .group(
                        kind: .sequence,
                        requestedCommand: command,
                        result: .multiple(children.map(\.result)),
                        stateBefore: stateBefore,
                        stateAfter: currentState,
                        children: children,
                        executedCommands: executedCommands
                    )
                }
            }

            return .group(
                kind: .sequence,
                requestedCommand: command,
                result: .multiple(children.map(\.result)),
                stateBefore: stateBefore,
                stateAfter: currentState,
                children: children,
                executedCommands: executedCommands
            )

        case .whenCancelled(let primary, let fallback):
            let snapshot = currentState
            var primaryState = snapshot
            let primaryJournal = planTransaction(
                primary,
                state: &primaryState,
                middlewareRegistry: middlewareRegistry,
                engine: engine
            )
            if primaryJournal.result.isSuccess {
                currentState = primaryState
                return .group(
                    kind: .whenCancelled,
                    requestedCommand: command,
                    result: primaryJournal.result,
                    stateBefore: snapshot,
                    stateAfter: currentState,
                    children: [primaryJournal],
                    executedCommands: primaryJournal.executedCommands
                )
            }

            var fallbackState = snapshot
            let fallbackJournal = planTransaction(
                fallback,
                state: &fallbackState,
                middlewareRegistry: middlewareRegistry,
                engine: engine
            )
            let fallbackSucceeded = fallbackJournal.result.isSuccess
            currentState = fallbackSucceeded ? fallbackState : snapshot
            return .group(
                kind: .whenCancelled,
                requestedCommand: command,
                result: fallbackJournal.result,
                stateBefore: snapshot,
                stateAfter: currentState,
                children: [
                    primaryJournal.forDiscardedTransaction(),
                    fallbackSucceeded ? fallbackJournal : fallbackJournal.forDiscardedTransaction(),
                ],
                executedCommands: primaryJournal.executedCommands + fallbackJournal.executedCommands
            )

        default:
            let disposition: LeafDisposition = .wrapperOnly
            let leaf = planLeaf(
                command,
                state: &currentState,
                middlewareRegistry: middlewareRegistry,
                engine: engine,
                disposition: disposition
            )
            if leaf.result.isSuccess {
                return leaf.withLeafDisposition(.publicDidExecute)
            }
            return leaf.withLeafDisposition(.discardCleanup)
        }
    }

    func finalizePreview(
        using middlewareRegistry: NavigationMiddlewareRegistry<R>
    ) -> NavigationResult<R> {
        guard let effectiveCommand, let participants else { return result }
        return middlewareRegistry.didExecute(
            effectiveCommand,
            result: result,
            state: stateAfter,
            participants: participants
        )
    }

    func finalizeCommittedTransaction(
        using middlewareRegistry: NavigationMiddlewareRegistry<R>
    ) -> NavigationResult<R> {
        switch kind {
        case .leaf:
            guard leafDisposition == .publicDidExecute,
                  let effectiveCommand,
                  let participants else {
                if leafDisposition == .discardCleanup,
                   let effectiveCommand,
                   let participants {
                    middlewareRegistry.discardExecution(
                        effectiveCommand,
                        result: result,
                        state: stateAfter,
                        participants: participants
                    )
                }
                return result
            }
            return middlewareRegistry.didExecute(
                effectiveCommand,
                result: result,
                state: stateAfter,
                participants: participants
            )

        case .sequence:
            return .multiple(children.map { $0.finalizeCommittedTransaction(using: middlewareRegistry) })

        case .whenCancelled:
            var lastPublicResult: NavigationResult<R>?
            for child in children.reversed() where child.containsPublicDidExecute {
                lastPublicResult = child.result
                break
            }

            var finalizedPublicResult: NavigationResult<R>?
            for child in children {
                let childResult = child.finalizeCommittedTransaction(using: middlewareRegistry)
                if child.containsPublicDidExecute {
                    finalizedPublicResult = childResult
                }
            }
            return finalizedPublicResult ?? lastPublicResult ?? result
        }
    }

    func discardExecuted(
        using middlewareRegistry: NavigationMiddlewareRegistry<R>
    ) {
        switch kind {
        case .leaf:
            guard leafDisposition == .discardCleanup,
                  let effectiveCommand,
                  let participants else { return }
            middlewareRegistry.discardExecution(
                effectiveCommand,
                result: result,
                state: stateAfter,
                participants: participants
            )

        case .sequence, .whenCancelled:
            for child in children {
                child.discardExecuted(using: middlewareRegistry)
            }
        }
    }

    func forDiscardedTransaction() -> Self {
        switch kind {
        case .leaf:
            if leafDisposition == .publicDidExecute {
                return withLeafDisposition(.discardCleanup)
            }
            return self

        case .sequence, .whenCancelled:
            return Self(
                kind: kind,
                requestedCommand: requestedCommand,
                effectiveCommand: effectiveCommand,
                participants: participants,
                result: result,
                stateBefore: stateBefore,
                stateAfter: stateAfter,
                children: children.map { $0.forDiscardedTransaction() },
                leafDisposition: leafDisposition,
                executedCommands: executedCommands
            )
        }
    }

    private var containsPublicDidExecute: Bool {
        switch kind {
        case .leaf:
            return leafDisposition == .publicDidExecute
        case .sequence, .whenCancelled:
            return children.contains { $0.containsPublicDidExecute }
        }
    }

    private func withLeafDisposition(_ disposition: LeafDisposition) -> Self {
        Self(
            kind: kind,
            requestedCommand: requestedCommand,
            effectiveCommand: effectiveCommand,
            participants: participants,
            result: result,
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            children: children,
            leafDisposition: disposition,
            executedCommands: executedCommands
        )
    }

    private static func group(
        kind: Kind,
        requestedCommand: NavigationCommand<R>,
        result: NavigationResult<R>,
        stateBefore: RouteStack<R>,
        stateAfter: RouteStack<R>,
        children: [Self],
        executedCommands: [NavigationCommand<R>]
    ) -> Self {
        Self(
            kind: kind,
            requestedCommand: requestedCommand,
            effectiveCommand: nil,
            participants: nil,
            result: result,
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            children: children,
            leafDisposition: .wrapperOnly,
            executedCommands: executedCommands
        )
    }

    private static func planLeaf(
        _ command: NavigationCommand<R>,
        state currentState: inout RouteStack<R>,
        middlewareRegistry: NavigationMiddlewareRegistry<R>,
        engine: NavigationEngine<R>,
        disposition: LeafDisposition
    ) -> Self {
        let stateBefore = currentState
        let interceptionOutcome = middlewareRegistry.intercept(command, state: stateBefore)
        switch interceptionOutcome.interception {
        case .cancel(let reason):
            let result: NavigationResult<R> = .cancelled(reason)
            return Self(
                kind: .leaf,
                requestedCommand: command,
                effectiveCommand: interceptionOutcome.command,
                participants: interceptionOutcome.participants,
                result: result,
                stateBefore: stateBefore,
                stateAfter: currentState,
                children: [],
                leafDisposition: disposition,
                executedCommands: []
            )

        case .proceed(let commandToExecute):
            let result = engine.apply(commandToExecute, to: &currentState)
            return Self(
                kind: .leaf,
                requestedCommand: command,
                effectiveCommand: commandToExecute,
                participants: interceptionOutcome.participants,
                result: result,
                stateBefore: stateBefore,
                stateAfter: currentState,
                children: [],
                leafDisposition: disposition,
                executedCommands: [commandToExecute]
            )
        }
    }
}
