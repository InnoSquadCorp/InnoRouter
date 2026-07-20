// MARK: - ModalStateReducer.swift
// InnoRouterSwiftUI - pure modal state planning for Flow previews.
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

/// Computes modal state transitions without owning observable state or
/// delivering lifecycle events. `ModalStore` keeps live mutation and event
/// ordering; Flow previews use this reducer to plan atomic commits.
@MainActor
enum ModalStateReducer<M: Route> {
    static func apply(
        _ command: ModalCommand<M>,
        to state: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        switch command {
        case .present(let presentation):
            return present(presentation, on: state)
        case .replaceCurrent(let presentation):
            return replaceCurrent(presentation, on: state)
        case .dismissCurrent(let reason):
            return dismissCurrent(reason: reason, on: state)
        case .dismissAll:
            return dismissAll(on: state)
        }
    }

    static func applyingCancellation(
        policy: ModalQueueCancellationPolicy<M>,
        command: ModalCommand<M>,
        reason: ModalCancellationReason<M>,
        to state: ModalExecutionState<M>
    ) -> ModalExecutionState<M> {
        guard !state.queuedPresentations.isEmpty else { return state }

        switch policy.resolve(command: command, reason: reason) {
        case .preserve:
            return state
        case .dropQueued:
            return makeState(
                currentPresentation: state.currentPresentation,
                queuedPresentations: []
            )
        }
    }

    static func makeState(
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) -> ModalExecutionState<M> {
        guard currentPresentation == nil, let firstQueued = queuedPresentations.first else {
            return ModalExecutionState(
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            )
        }

        return ModalExecutionState(
            currentPresentation: firstQueued,
            queuedPresentations: Array(queuedPresentations.dropFirst())
        )
    }

    private static func present(
        _ presentation: ModalPresentation<M>,
        on state: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        if state.currentPresentation == nil {
            return (
                .executed(.present(presentation)),
                makeState(
                    currentPresentation: presentation,
                    queuedPresentations: state.queuedPresentations
                )
            )
        }

        return (
            .queued(presentation),
            makeState(
                currentPresentation: state.currentPresentation,
                queuedPresentations: state.queuedPresentations + [presentation]
            )
        )
    }

    private static func replaceCurrent(
        _ presentation: ModalPresentation<M>,
        on state: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        guard let currentPresentation = state.currentPresentation else {
            return (.noop, state)
        }
        guard currentPresentation != presentation else {
            return (.noop, state)
        }

        return (
            .executed(.replaceCurrent(presentation)),
            makeState(
                currentPresentation: presentation,
                queuedPresentations: state.queuedPresentations
            )
        )
    }

    private static func dismissCurrent(
        reason: ModalDismissalReason,
        on state: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        guard state.currentPresentation != nil else {
            return (.noop, state)
        }

        return (
            .executed(.dismissCurrent(reason: reason)),
            makeState(
                currentPresentation: nil,
                queuedPresentations: state.queuedPresentations
            )
        )
    }

    private static func dismissAll(
        on state: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        guard state.currentPresentation != nil || !state.queuedPresentations.isEmpty else {
            return (.noop, state)
        }

        return (
            .executed(.dismissAll),
            makeState(currentPresentation: nil, queuedPresentations: [])
        )
    }
}
