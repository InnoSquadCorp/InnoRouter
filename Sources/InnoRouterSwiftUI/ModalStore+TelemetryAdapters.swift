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

    static func makePublicTelemetryRecorder(
        onMiddlewareMutation: (@MainActor @Sendable (ModalMiddlewareMutationEvent<M>) -> Void)?
    ) -> ModalStoreTelemetryRecorder<M>? {
        guard let onMiddlewareMutation else { return nil }
        return { @MainActor event in
            switch event {
            case .middlewareMutation(let action, let metadata, let index):
                onMiddlewareMutation(
                    ModalMiddlewareMutationEvent(
                        action: Self.publicAction(for: action),
                        metadata: metadata,
                        index: index
                    )
                )
            case .presented, .dismissed, .replaced, .queued, .queueChanged, .commandIntercepted:
                break
            }
        }
    }

    static func makeBroadcastRecorder(
        broadcaster: EventBroadcaster<ModalEvent<M>>
    ) -> ModalStoreTelemetryRecorder<M>? {
        { @MainActor event in
            switch event {
            case .presented(let presentation):
                broadcaster.broadcast(.presented(presentation))
            case .dismissed(let presentation, let reason):
                broadcaster.broadcast(.dismissed(presentation, reason: reason))
            case .replaced(let oldPresentation, let newPresentation):
                broadcaster.broadcast(.replaced(old: oldPresentation, new: newPresentation))
            case .queueChanged(let oldQueue, let newQueue):
                broadcaster.broadcast(.queueChanged(old: oldQueue, new: newQueue))
            case .middlewareMutation(let action, let metadata, let index):
                broadcaster.broadcast(
                    .middlewareMutation(
                        ModalMiddlewareMutationEvent(
                            action: Self.publicAction(for: action),
                            metadata: metadata,
                            index: index
                        )
                    )
                )
            case .commandIntercepted(let command, let outcome, let cancellationReason):
                let result = Self.executionResult(
                    for: command,
                    outcome: outcome,
                    cancellationReason: cancellationReason
                )
                broadcaster.broadcast(
                    .commandIntercepted(command: command, result: result)
                )
            case .queued:
                // .queued is an internal side-signal emitted alongside
                // .queueChanged; the public ModalEvent surface folds
                // queueing into queueChanged, so we skip it here.
                break
            }
        }
    }

    static func makeTelemetrySinkRecorder(
        telemetrySink: AnyModalTelemetrySink<M>?
    ) -> ModalStoreTelemetryRecorder<M>? {
        guard let telemetrySink else { return nil }
        return { @MainActor event in
            switch event {
            case .presented(let presentation):
                telemetrySink.record(.presented(presentation))
            case .dismissed(let presentation, let reason):
                telemetrySink.record(.dismissed(presentation, reason: reason))
            case .replaced(let oldPresentation, let newPresentation):
                telemetrySink.record(.replaced(old: oldPresentation, new: newPresentation))
            case .queueChanged(let oldQueue, let newQueue):
                telemetrySink.record(.queueChanged(old: oldQueue, new: newQueue))
            case .middlewareMutation(let action, let metadata, let index):
                telemetrySink.record(
                    .middlewareMutation(
                        ModalMiddlewareMutationEvent(
                            action: Self.publicAction(for: action),
                            metadata: metadata,
                            index: index
                        )
                    )
                )
            case .commandIntercepted(let command, let outcome, let cancellationReason):
                let result = Self.executionResult(
                    for: command,
                    outcome: outcome,
                    cancellationReason: cancellationReason
                )
                telemetrySink.record(.commandIntercepted(command: command, result: result))
            case .queued:
                break
            }
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

    static func combineRecorders(
        _ primary: ModalStoreTelemetryRecorder<M>?,
        _ secondary: ModalStoreTelemetryRecorder<M>?
    ) -> ModalStoreTelemetryRecorder<M>? {
        switch (primary, secondary) {
        case (nil, nil):
            return nil
        case (let primary?, nil):
            return primary
        case (nil, let secondary?):
            return secondary
        case (let primary?, let secondary?):
            return { event in
                primary(event)
                secondary(event)
            }
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
