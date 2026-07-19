// MARK: - FlowStore+ModalPlanning.swift
// InnoRouterSwiftUI — modal reset preview planning.

import InnoRouterCore

@MainActor
extension FlowStore {
    internal func previewModalReset(
        to modalTail: RouteStep<R>?,
        from initialState: ModalExecutionState<R>
    ) -> ModalPreviewPlan {
        let targetPresentation = modalTail.map(Self.presentation(for:))

        if Self.matchesPresentationSemantics(initialState.currentPresentation, targetPresentation),
            initialState.queuedPresentations.isEmpty {
            return .commit([])
        }

        var journals: [ModalExecutionJournal<R>] = []
        var shadow = initialState

        if shadow.currentPresentation != nil || !shadow.queuedPresentations.isEmpty {
            let dismissJournal = modalStore.previewFlowCommand(.dismissAll, from: shadow)
            if case .cancelled(let reason) = dismissJournal.result {
                return .rejected(
                    reason,
                    discardedJournals: journals,
                    cancellationJournal: dismissJournal
                )
            }
            journals.append(dismissJournal)
            shadow = dismissJournal.stateAfter
        }

        if let targetPresentation {
            let presentJournal = modalStore.previewFlowCommand(.present(targetPresentation), from: shadow)
            if case .cancelled(let reason) = presentJournal.result {
                return .rejected(
                    reason,
                    discardedJournals: journals,
                    cancellationJournal: presentJournal
                )
            }
            journals.append(presentJournal)
        }

        return .commit(journals)
    }

    internal enum ModalPreviewPlan {
        case commit([ModalExecutionJournal<R>])
        case rejected(
            ModalCancellationReason<R>,
            discardedJournals: [ModalExecutionJournal<R>],
            cancellationJournal: ModalExecutionJournal<R>
        )
    }
}
