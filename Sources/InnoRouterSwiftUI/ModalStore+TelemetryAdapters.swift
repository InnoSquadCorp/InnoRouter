import InnoRouterCore

// MARK: - Telemetry adapter helpers
//
// Internal static helpers that translate between the underlying
// `ModalStoreTelemetryEvent` enum and the public-facing
// `ModalMiddlewareMutationEvent` / `ModalExecutionResult` shapes,
// extracted from `ModalStore.swift` so the primary class definition
// stays focused on the `Observable` storage and execution surface.
// Visibility is bumped from `private` to `internal` because the
// initialiser call sites cross file boundaries; the helpers stay
// absent from the public-API baseline because they remain non-public.
extension ModalStore {
    static func publicEvent(
        for event: ModalStoreTelemetryEvent<M>
    ) -> ModalEvent<M>? {
        switch event {
        case .presented(let presentation):
            return .presented(presentation)
        case .dismissed(let presentation, let reason):
            return .dismissed(presentation, reason: reason)
        case .replaced(let oldPresentation, let newPresentation):
            return .replaced(old: oldPresentation, new: newPresentation)
        case .queueChanged(let oldQueue, let newQueue):
            return .queueChanged(old: oldQueue, new: newQueue)
        case .middlewareMutation(let action, let metadata, let index):
            return .middlewareMutation(
                ModalMiddlewareMutationEvent(
                    action: Self.publicAction(for: action),
                    metadata: metadata,
                    index: index
                )
            )
        case .commandIntercepted(let command, let outcome, let cancellationReason):
            return .commandIntercepted(
                command: command,
                result: Self.executionResult(
                    for: command,
                    outcome: outcome,
                    cancellationReason: cancellationReason
                )
            )
        case .queued:
            // `.queued` is an internal side-signal emitted alongside
            // `.queueChanged`; the public surface folds queueing into that
            // event so every observer sees exactly one queue mutation.
            return nil
        }
    }

    static func executionResult(
        for command: ModalCommand<M>,
        outcome: ModalStoreTelemetryEvent<M>.InterceptionOutcomeKind,
        cancellationReason: ModalCancellationReason<M>?
    ) -> ModalExecutionResult<M> {
        switch outcome {
        case .executed:
            return .executed(command)
        case .queued:
            // .queued is only produced by `.present(presentation)`
            // commands that were deferred behind an active modal.
            if case .present(let presentation) = command {
                return .queued(presentation)
            }
            // Should be unreachable — fall through as .executed so the
            // surface still type-checks.
            return .executed(command)
        case .cancelled:
            return .cancelled(cancellationReason ?? .custom("unknown"))
        case .noop:
            return .noop
        }
    }

    static func defaultTelemetrySink(
        for configuration: ModalStoreConfiguration<M>
    ) -> AnyModalTelemetrySink<M>? {
        if let telemetrySink = configuration.telemetrySink {
            return telemetrySink
        }
        guard let logger = configuration.logger else { return nil }
        return AnyModalTelemetrySink(OSLogModalTelemetrySink<M>(logger: logger))
    }

    static func publicAction(
        for action: ModalStoreTelemetryEvent<M>.MiddlewareMutation
    ) -> ModalMiddlewareMutationEvent<M>.Action {
        switch action {
        case .added: return .added
        case .inserted: return .inserted
        case .removed: return .removed
        case .replaced: return .replaced
        case .moved: return .moved
        }
    }
}
