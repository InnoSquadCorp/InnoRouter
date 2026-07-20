import SwiftUI

import InnoRouterCore

// MARK: - State transition reducer

extension ModalStore {
    func applyCommand(_ command: ModalCommand<M>) -> ModalExecutionResult<M> {
        switch command {
        case .present(let presentation):
            return applyPresent(presentation)
        case .replaceCurrent(let presentation):
            return applyReplaceCurrent(presentation)
        case .dismissCurrent(let reason):
            return applyDismissCurrent(reason: reason)
        case .dismissAll:
            return applyDismissAll()
        }
    }

    private func applyPresent(_ presentation: ModalPresentation<M>) -> ModalExecutionResult<M> {
        if currentPresentation == nil {
            currentPresentation = presentation
            telemetrySink.recordPresented(presentation)
            return .executed(.present(presentation))
        } else {
            let oldQueue = queuedPresentations
            queuedPresentations.append(presentation)
            telemetrySink.recordQueued(presentation)
            telemetrySink.recordQueueChanged(oldQueue: oldQueue, newQueue: queuedPresentations)
            return .queued(presentation)
        }
    }

    private func applyReplaceCurrent(_ presentation: ModalPresentation<M>) -> ModalExecutionResult<M> {
        guard let currentPresentation else {
            return .noop
        }

        guard currentPresentation != presentation else {
            return .noop
        }

        self.currentPresentation = presentation
        telemetrySink.recordReplaced(old: currentPresentation, new: presentation)
        return .executed(.replaceCurrent(presentation))
    }

    private func applyDismissCurrent(reason: ModalDismissalReason) -> ModalExecutionResult<M> {
        guard let dismissedPresentation = currentPresentation else {
            return .noop
        }
        currentPresentation = nil
        telemetrySink.recordDismissed(dismissedPresentation, reason: reason)
        promoteNextPresentationIfNeeded()
        return .executed(.dismissCurrent(reason: reason))
    }

    private func applyDismissAll() -> ModalExecutionResult<M> {
        let dismissedPresentation = currentPresentation
        let oldQueue = queuedPresentations
        if dismissedPresentation == nil && oldQueue.isEmpty {
            return .noop
        }
        currentPresentation = nil
        queuedPresentations.removeAll()
        if oldQueue != queuedPresentations {
            telemetrySink.recordQueueChanged(oldQueue: oldQueue, newQueue: queuedPresentations)
        }
        if let dismissedPresentation {
            telemetrySink.recordDismissed(dismissedPresentation, reason: .dismissAll)
        }
        return .executed(.dismissAll)
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

    private func promoteNextPresentationIfNeeded() {
        guard currentPresentation == nil, !queuedPresentations.isEmpty else { return }
        let oldQueue = queuedPresentations
        let promotedPresentation = queuedPresentations.removeFirst()
        currentPresentation = promotedPresentation
        telemetrySink.recordQueueChanged(oldQueue: oldQueue, newQueue: queuedPresentations)
        telemetrySink.recordPresented(promotedPresentation)
    }

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
