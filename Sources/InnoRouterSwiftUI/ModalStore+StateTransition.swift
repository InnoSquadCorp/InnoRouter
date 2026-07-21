import SwiftUI

import InnoRouterCore

// MARK: - State transition reducer

extension ModalStore {
    func applyCommand(_ command: ModalCommand<M>) -> ModalExecutionResult<M> {
        let stateBefore = flowStateSnapshot
        let outcome = ModalStateReducer<M>.apply(command, to: stateBefore)
        let journal = ModalExecutionJournal(
            requestedCommand: command,
            effectiveCommand: command,
            result: outcome.result,
            participants: [],
            stateBefore: stateBefore,
            stateAfter: outcome.stateAfter
        )

        currentPresentation = outcome.stateAfter.currentPresentation
        queuedPresentations = outcome.stateAfter.queuedPresentations
        emitCommittedEvents(for: journal)
        return outcome.result
    }

    func binding(for style: ModalPresentationStyle) -> Binding<ModalPresentation<M>?> {
        binding(for: [style])
    }

    func binding(for styles: Set<ModalPresentationStyle>) -> Binding<ModalPresentation<M>?> {
        Binding(
            get: { [self] in
                guard let currentPresentation, styles.contains(currentPresentation.style) else { return nil }
                return currentPresentation
            },
            set: { [self] newValue in
                guard newValue == nil else { return }
                self.dismissCurrent(reason: .systemDismiss)
            }
        )
    }

    // Note: binding(case:style:) lives in
    // `ModalStore+Binding.swift`.

    /// Applies the configured ``ModalQueueCancellationPolicy`` to
    /// ``queuedPresentations`` after a middleware cancellation. The
    /// active presentation is never touched here — only the queue.
    /// Emits a `queueChanged` event when the queue actually shrinks so
    /// `onEvent` observers (and `events` subscribers) see the
    /// drop without polling state.
    func applyQueueCancellationPolicy(
        command: ModalCommand<M>,
        reason: ModalCancellationReason<M>
    ) {
        let stateBefore = flowStateSnapshot
        let stateAfter = ModalStateReducer<M>.applyingCancellation(
            policy: queueCancellationPolicy,
            command: command,
            reason: reason,
            to: stateBefore
        )
        guard stateAfter != stateBefore else { return }

        currentPresentation = stateAfter.currentPresentation
        queuedPresentations = stateAfter.queuedPresentations
        telemetrySink.recordQueueChanged(
            oldQueue: stateBefore.queuedPresentations,
            newQueue: stateAfter.queuedPresentations
        )
    }

    func emitCommittedEvents(for preview: ModalExecutionJournal<M>) {
        switch preview.result {
        case .executed(.present(let presentation)):
            telemetrySink.recordPresented(presentation)

        case .executed(.replaceCurrent(let presentation)):
            guard let replacedPresentation = preview.stateBefore.currentPresentation else { return }
            telemetrySink.recordReplaced(old: replacedPresentation, new: presentation)

        case .executed(.dismissCurrent(let reason)):
            guard let dismissedPresentation = preview.stateBefore.currentPresentation else { return }
            telemetrySink.recordDismissed(dismissedPresentation, reason: reason)

            if preview.stateBefore.queuedPresentations != preview.stateAfter.queuedPresentations {
                telemetrySink.recordQueueChanged(
                    oldQueue: preview.stateBefore.queuedPresentations,
                    newQueue: preview.stateAfter.queuedPresentations
                )
            }

            if let promotedPresentation = preview.stateAfter.currentPresentation {
                telemetrySink.recordPresented(promotedPresentation)
            }

        case .executed(.dismissAll):
            if preview.stateBefore.queuedPresentations != preview.stateAfter.queuedPresentations {
                telemetrySink.recordQueueChanged(
                    oldQueue: preview.stateBefore.queuedPresentations,
                    newQueue: preview.stateAfter.queuedPresentations
                )
            }

            if let dismissedPresentation = preview.stateBefore.currentPresentation {
                telemetrySink.recordDismissed(dismissedPresentation, reason: .dismissAll)
            }

        case .queued(let presentation):
            telemetrySink.recordQueued(presentation)
            telemetrySink.recordQueueChanged(
                oldQueue: preview.stateBefore.queuedPresentations,
                newQueue: preview.stateAfter.queuedPresentations
            )

        case .cancelled:
            if preview.stateBefore.queuedPresentations != preview.stateAfter.queuedPresentations {
                telemetrySink.recordQueueChanged(
                    oldQueue: preview.stateBefore.queuedPresentations,
                    newQueue: preview.stateAfter.queuedPresentations
                )
            }

        case .noop:
            break
        }
    }

    static func outcomeKind(
        for result: ModalExecutionResult<M>
    ) -> ModalStoreTelemetryEvent<M>.InterceptionOutcomeKind {
        switch result {
        case .executed: return .executed
        case .queued: return .queued
        case .cancelled: return .cancelled
        case .noop: return .noop
        }
    }
}
