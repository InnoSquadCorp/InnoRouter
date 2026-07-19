import InnoRouterCore

// MARK: - Command execution

extension NavigationStore {
    @discardableResult
    public func execute(_ command: NavigationCommand<R>) -> NavigationResult<R> {
        if let rejection = reentrantMiddlewareRejection(operation: "execute") {
            return rejection
        }

        return eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "execute",
                recorder: effectiveTraceRecorder,
                metadata: ["command": String(describing: command)]
            ) {
                executeSingle(command, shouldNotifyOnChange: true).result
            } outcome: { result in
                String(describing: result)
            }
        }
    }

    @discardableResult
    public func executeBatch(
        _ commands: [NavigationCommand<R>],
        stopOnFailure: Bool = false
    ) -> NavigationBatchResult<R> {
        if let rejection = reentrantMiddlewareRejection(operation: "executeBatch") {
            let snapshot = state
            return NavigationBatchResult(
                requestedCommands: commands,
                executedCommands: [],
                results: commands.map { _ in rejection },
                stateBefore: snapshot,
                stateAfter: snapshot,
                hasStoppedOnFailure: false
            )
        }

        return eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "executeBatch",
                recorder: effectiveTraceRecorder,
                metadata: [
                    "count": String(commands.count),
                    "stopOnFailure": String(stopOnFailure),
                ]
            ) {
                let stateBefore = state
                var executedCommands: [NavigationCommand<R>] = []
                executedCommands.reserveCapacity(commands.count)
                var results: [NavigationResult<R>] = []
                results.reserveCapacity(commands.count)
                var hasStoppedOnFailure = false

                for command in commands {
                    let outcome = executeSingle(command, shouldNotifyOnChange: false)
                    executedCommands.append(contentsOf: outcome.executedCommands)
                    results.append(outcome.result)

                    if stopOnFailure && !outcome.result.isSuccess {
                        hasStoppedOnFailure = true
                        break
                    }
                }

                let stateAfter = state
                if stateAfter != stateBefore {
                    emitObservationEvent(.changed(from: stateBefore, to: stateAfter))
                }

                let batch = NavigationBatchResult(
                    requestedCommands: commands,
                    executedCommands: executedCommands,
                    results: results,
                    stateBefore: stateBefore,
                    stateAfter: stateAfter,
                    hasStoppedOnFailure: hasStoppedOnFailure
                )
                emitObservationEvent(.batchExecuted(batch))
                return batch
            } outcome: { batch in
                batch.isSuccess ? "success" : "failure"
            }
        }
    }

    @discardableResult
    public func executeTransaction(
        _ commands: [NavigationCommand<R>]
    ) -> NavigationTransactionResult<R> {
        if let rejection = reentrantMiddlewareRejection(operation: "executeTransaction") {
            let snapshot = state
            return NavigationTransactionResult(
                requestedCommands: commands,
                executedCommands: [],
                results: commands.isEmpty ? [] : [rejection],
                stateBefore: snapshot,
                stateAfter: snapshot,
                failureIndex: commands.isEmpty ? nil : 0,
                isCommitted: false
            )
        }

        return eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "executeTransaction",
                recorder: effectiveTraceRecorder,
                metadata: ["count": String(commands.count)]
            ) {
                let stateBefore = state
                var shadowState = state
                var journals: [NavigationExecutionJournal<R>] = []
                journals.reserveCapacity(commands.count)
                var failureIndex: Int?

                for (index, command) in commands.enumerated() {
                    let journal = executionCoordinator.planTransaction(
                        command,
                        state: &shadowState
                    )
                    journals.append(journal)

                    if journal.result.isSuccess {
                        continue
                    } else {
                        failureIndex = index
                        break
                    }
                }

                let isCommitted = !commands.isEmpty && failureIndex == nil
                let executedCommands = journals.flatMap(\.executedCommands)
                let results: [NavigationResult<R>]
                if isCommitted {
                    assignState(shadowState)
                    results = journals.map(executionCoordinator.finalizeCommittedTransaction)
                    if state != stateBefore {
                        emitObservationEvent(.changed(from: stateBefore, to: state))
                    }
                } else {
                    journals
                        .map { $0.forDiscardedTransaction() }
                        .forEach(executionCoordinator.discardExecuted)
                    results = journals.map(\.result)
                }

                let transaction = NavigationTransactionResult(
                    requestedCommands: commands,
                    executedCommands: executedCommands,
                    results: results,
                    stateBefore: stateBefore,
                    stateAfter: isCommitted ? state : stateBefore,
                    failureIndex: failureIndex,
                    isCommitted: isCommitted
                )
                emitObservationEvent(.transactionExecuted(transaction))
                return transaction
            } outcome: { transaction in
                if commands.isEmpty {
                    "empty"
                } else {
                    transaction.isCommitted ? "committed" : "rolledBack"
                }
            }
        }
    }

    private func executeSingle(
        _ command: NavigationCommand<R>,
        shouldNotifyOnChange: Bool
    ) -> NavigationExecutionOutcome<R> {
        if shouldNotifyOnChange, case .sequence(let commands) = command {
            let outcomes = commands.map {
                executeSingle($0, shouldNotifyOnChange: true)
            }
            return NavigationExecutionOutcome(
                executedCommands: outcomes.flatMap(\.executedCommands),
                result: .multiple(outcomes.map(\.result)),
                observationEvents: []
            )
        }

        var workingState = state
        let outcome = executionCoordinator.execute(
            command,
            state: &workingState,
            shouldNotifyOnChange: shouldNotifyOnChange
        )
        assignState(workingState)
        for event in outcome.observationEvents {
            emitObservationEvent(event)
        }
        return outcome
    }
}
