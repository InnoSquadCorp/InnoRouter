import InnoRouterCore

@MainActor
extension ModalStore {
    var flowStateSnapshot: ModalExecutionState<M> {
        ModalStateReducer<M>.makeState(
            currentPresentation: currentPresentation,
            queuedPresentations: queuedPresentations
        )
    }

    func previewFlowCommand(_ command: ModalCommand<M>) -> ModalExecutionJournal<M> {
        previewFlowCommand(command, from: flowStateSnapshot)
    }

    func previewFlowCommand(
        _ command: ModalCommand<M>,
        from stateBefore: ModalExecutionState<M>
    ) -> ModalExecutionJournal<M> {
        let outcome = middlewareRegistry.intercept(
            command,
            currentPresentation: stateBefore.currentPresentation,
            queuedPresentations: stateBefore.queuedPresentations
        )

        switch outcome.interception {
        case .cancel(let reason):
            let stateAfter = ModalStateReducer<M>.applyingCancellation(
                policy: queueCancellationPolicy,
                command: outcome.command,
                reason: reason,
                to: stateBefore
            )
            return ModalExecutionJournal(
                requestedCommand: command,
                effectiveCommand: outcome.command,
                result: .cancelled(reason),
                participants: outcome.participants,
                stateBefore: stateBefore,
                stateAfter: stateAfter
            )
        case .proceed(let effectiveCommand):
            let previewOutcome = ModalStateReducer<M>.apply(effectiveCommand, to: stateBefore)
            return ModalExecutionJournal(
                requestedCommand: command,
                effectiveCommand: effectiveCommand,
                result: previewOutcome.result,
                participants: outcome.participants,
                stateBefore: stateBefore,
                stateAfter: previewOutcome.stateAfter
            )
        }
    }

    @discardableResult
    func commitFlowPreview(_ preview: ModalExecutionJournal<M>) -> ModalExecutionResult<M> {
        commitFlowPreview(preview, appliesState: true)
    }

    /// Finalizes a cancelled modal preview captured by `FlowStore`.
    ///
    /// A cancellation can still change the modal queue through
    /// ``ModalQueueCancellationPolicy``. That shadow-state delta is committed
    /// only when the journal was previewed from the current live state. A
    /// later leg of an aborted reset was previewed from an intermediate shadow
    /// instead; in that case middleware and telemetry are finalized against
    /// the actual live post-state without leaking the uncommitted shadow.
    @discardableResult
    func commitFlowCancellation(
        _ preview: ModalExecutionJournal<M>
    ) -> ModalExecutionResult<M> {
        guard case .cancelled = preview.result else {
            preconditionFailure("commitFlowCancellation requires a cancelled preview.")
        }
        return commitFlowPreview(
            preview,
            appliesState: flowStateSnapshot == preview.stateBefore
        )
    }

    @discardableResult
    private func commitFlowPreview(
        _ preview: ModalExecutionJournal<M>,
        appliesState: Bool
    ) -> ModalExecutionResult<M> {
        eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .modal,
                operation: "commitFlowPreview",
                recorder: effectiveTraceRecorder,
                metadata: ["command": String(describing: preview.requestedCommand)]
            ) {
                if appliesState {
                    currentPresentation = preview.stateAfter.currentPresentation
                    queuedPresentations = preview.stateAfter.queuedPresentations

                    emitCommittedEvents(for: preview)
                }

                // `didExecute` is a post-state callback. For an ordinary commit
                // the live snapshot now equals `preview.stateAfter`. For a
                // cancellation previewed from an aborted reset's intermediate
                // shadow, no shadow state was committed, so participants must see
                // the real live state that survived rollback instead.
                let finalState = flowStateSnapshot

                middlewareRegistry.didExecute(
                    preview.effectiveCommand,
                    currentPresentation: finalState.currentPresentation,
                    queuedPresentations: finalState.queuedPresentations,
                    participants: preview.participants
                )

                if case .cancelled(let reason) = preview.result {
                    telemetrySink.recordCommandIntercepted(
                        command: preview.effectiveCommand,
                        outcome: .cancelled,
                        cancellationReason: reason
                    )
                } else {
                    telemetrySink.recordCommandIntercepted(
                        command: preview.effectiveCommand,
                        outcome: Self.outcomeKind(for: preview.result),
                        cancellationReason: nil
                    )
                }

                return preview.result
            } outcome: { result in
                String(describing: result)
            }
        }
    }

    /// Balances package-owned middleware lifecycle for a modal preview that
    /// an enclosing FlowStore reset rolled back.
    ///
    /// Public `didExecute` is intentionally not called because the preview's
    /// state never became live. Stateful package middleware can opt into the
    /// same discard-cleanup model used by navigation transactions.
    func discardFlowPreview(_ preview: ModalExecutionJournal<M>) {
        middlewareRegistry.discardExecution(
            preview.effectiveCommand,
            currentPresentation: preview.stateAfter.currentPresentation,
            queuedPresentations: preview.stateAfter.queuedPresentations,
            participants: preview.participants
        )
    }

    func commitFlowPreviews(_ previews: [ModalExecutionJournal<M>]) {
        eventDispatcher.withExecutionBoundary {
            for preview in previews {
                _ = commitFlowPreview(preview)
            }
        }
    }
}
