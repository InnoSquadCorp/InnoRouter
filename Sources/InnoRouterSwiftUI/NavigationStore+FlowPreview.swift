import InnoRouterCore

// MARK: - FlowStore preview lifecycle

extension NavigationStore {
    func previewFlowCommand(_ command: NavigationCommand<R>) -> NavigationExecutionJournal<R> {
        previewFlowCommand(command, from: state)
    }

    func previewFlowCommand(
        _ command: NavigationCommand<R>,
        from stateBefore: RouteStack<R>
    ) -> NavigationExecutionJournal<R> {
        executionCoordinator.preview(command, from: stateBefore)
    }

    @discardableResult
    func commitFlowPreview(_ preview: NavigationExecutionJournal<R>) -> NavigationResult<R> {
        eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "commitFlowPreview",
                recorder: effectiveTraceRecorder,
                metadata: ["command": String(describing: preview.requestedCommand)]
            ) {
                let committedStateBefore = state
                assignState(preview.stateAfter)

                let finalResult = executionCoordinator.finalizePreview(preview)

                if state != committedStateBefore {
                    emitObservationEvent(.changed(from: committedStateBefore, to: state))
                }

                return finalResult
            } outcome: { result in
                String(describing: result)
            }
        }
    }

    /// Balances middleware lifecycle for a preview that an enclosing
    /// `FlowStore` transaction ultimately rolls back.
    ///
    /// The live navigation state was never changed by the preview, so this
    /// only runs the middleware discard hook captured by the journal.
    func discardFlowPreview(_ preview: NavigationExecutionJournal<R>) {
        executionCoordinator.discardExecuted(preview.forDiscardedTransaction())
    }
}
