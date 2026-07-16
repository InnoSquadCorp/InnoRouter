import OSLog
import Observation
import SwiftUI

import InnoRouterCore

private struct ModalObservationDelivery<M: Route> {
    let event: ModalEvent<M>?
    let telemetryEvent: ModalStoreTelemetryEvent<M>
}

/// View-layer intent dispatched to ``ModalStore/send(_:)``.
///
/// Conformance to `Sendable` is **unconditional** because every ``Route`` is
/// required to be `Sendable`. Callers can therefore freely move `ModalIntent`
/// values across actor boundaries without additional `where M: Sendable`
/// constraints.
public enum ModalIntent<M: Route>: Sendable, Equatable {
    case present(M, style: ModalPresentationStyle)
    case dismiss
    case dismissAll
}

@Observable
@MainActor
public final class ModalStore<M: Route> {
    public internal(set) var currentPresentation: ModalPresentation<M>?
    public internal(set) var queuedPresentations: [ModalPresentation<M>] = []
    // Internal because state-transition helpers live in
    // `ModalStore+StateTransition.swift`.
    internal let queueCancellationPolicy: ModalQueueCancellationPolicy<M>
    private let eventDispatcher: SerializedEventDispatcher<ModalObservationDelivery<M>>
    internal let telemetrySink: ModalStoreTelemetrySink<M>
    // `middlewareRegistry` is `internal` rather than `private`
    // because middleware management methods live in
    // `ModalStore+Middleware.swift`.
    internal let middlewareRegistry: ModalMiddlewareRegistry<M>
    private let broadcaster: EventBroadcaster<ModalEvent<M>>
    private let traceLogger: Logger?
    private var traceRecorder: InternalExecutionTraceRecorder?
    /// Memoised forwarding closure that fans out trace records to both
    /// the externally-installed recorder (if any) and the internal
    /// `Logger`. Recomputed only when `installTraceRecorder(_:)` flips
    /// the underlying recorder so we don't allocate a new closure on
    /// every command execution.
    private var cachedEffectiveTraceRecorder: InternalExecutionTraceRecorder?
    /// Cached intent closure that lives for the lifetime of this store.
    /// Built on first access by ``intentDispatcher`` so SwiftUI hosts do
    /// not allocate a fresh closure on every render.
    @ObservationIgnored
    private var cachedIntentDispatcher: ModalIntentHandler<M>?

    /// A closure that forwards `ModalIntent` values to this store's
    /// ``send(_:)`` entry point.
    ///
    /// Hosts publish this through their unified router authority so descendants
    /// can use ``EnvironmentRouter`` without holding a direct store reference.
    /// The dispatcher is created on first access and reused for the lifetime of
    /// the store, so a SwiftUI host does not allocate a fresh closure on every
    /// render.
    var intentDispatcher: ModalIntentHandler<M> {
        if let cachedIntentDispatcher {
            return cachedIntentDispatcher
        }
        let dispatcher: ModalIntentHandler<M> = { [weak self] intent in
            self?.send(intent)
        }
        cachedIntentDispatcher = dispatcher
        return dispatcher
    }

    /// Ordered snapshot of the registered middleware identities and debug labels.
    public var middlewareMetadata: [ModalMiddlewareMetadata] {
        middlewareRegistry.metadata
    }

    /// A multicast `AsyncStream` that emits every observation event the
    /// modal store produces — presentations, replacements, dismissals,
    /// queue changes, command interceptions, and middleware registry mutations — in
    /// the same order as the synchronous
    /// ``ModalStoreConfiguration/onEvent`` callback.
    ///
    /// Each call to `events` returns a fresh stream with its own
    /// continuation; multiple subscribers see every event
    /// independently. Subscriber teardown (cancelled `for await` loop
    /// or store deallocation) cleans up the associated continuation.
    public var events: AsyncStream<ModalEvent<M>> {
        broadcaster.stream()
    }

    public init(
        currentPresentation: ModalPresentation<M>? = nil,
        queuedPresentations: [ModalPresentation<M>] = [],
        configuration: ModalStoreConfiguration<M> = .init()
    ) {
        let normalizedState = Self.normalize(
            currentPresentation: currentPresentation,
            queuedPresentations: queuedPresentations
        )
        let broadcaster = EventBroadcaster<ModalEvent<M>>(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        let observationTelemetrySink = Self.defaultTelemetrySink(for: configuration)
        let onEvent = configuration.onEvent
        let eventDispatcher = SerializedEventDispatcher<ModalObservationDelivery<M>> { delivery in
            guard let event = delivery.event else { return }
            onEvent?(event)
            observationTelemetrySink?.record(event)
            broadcaster.broadcast(event)
        }
        let telemetrySink = ModalStoreTelemetrySink<M>(
            logger: nil,
            recorder: { telemetryEvent in
                eventDispatcher.emit(
                    ModalObservationDelivery(
                        event: Self.publicEvent(for: telemetryEvent),
                        telemetryEvent: telemetryEvent
                    )
                )
            }
        )
        let middlewareRegistry = ModalMiddlewareRegistry(
            registrations: configuration.middlewares,
            telemetrySink: telemetrySink
        )
        self.currentPresentation = normalizedState.current
        self.queuedPresentations = normalizedState.queue
        self.queueCancellationPolicy = configuration.queueCancellationPolicy
        self.eventDispatcher = eventDispatcher
        self.telemetrySink = telemetrySink
        self.middlewareRegistry = middlewareRegistry
        self.broadcaster = broadcaster
        self.traceLogger = configuration.logger
        self.traceRecorder = nil
        updateEffectiveTraceRecorder()
    }

    init(
        currentPresentation: ModalPresentation<M>? = nil,
        queuedPresentations: [ModalPresentation<M>] = [],
        configuration: ModalStoreConfiguration<M> = .init(),
        telemetryRecorder: ModalStoreTelemetryRecorder<M>? = nil
    ) {
        let normalizedState = Self.normalize(
            currentPresentation: currentPresentation,
            queuedPresentations: queuedPresentations
        )
        let broadcaster = EventBroadcaster<ModalEvent<M>>(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        let observationTelemetrySink = Self.defaultTelemetrySink(for: configuration)
        let onEvent = configuration.onEvent
        let eventDispatcher = SerializedEventDispatcher<ModalObservationDelivery<M>> { delivery in
            if let event = delivery.event {
                onEvent?(event)
            }
            telemetryRecorder?(delivery.telemetryEvent)
            if let event = delivery.event {
                observationTelemetrySink?.record(event)
                broadcaster.broadcast(event)
            }
        }
        let telemetrySink = ModalStoreTelemetrySink(
            logger: nil,
            recorder: { telemetryEvent in
                eventDispatcher.emit(
                    ModalObservationDelivery(
                        event: Self.publicEvent(for: telemetryEvent),
                        telemetryEvent: telemetryEvent
                    )
                )
            }
        )
        let middlewareRegistry = ModalMiddlewareRegistry(
            registrations: configuration.middlewares,
            telemetrySink: telemetrySink
        )
        self.currentPresentation = normalizedState.current
        self.queuedPresentations = normalizedState.queue
        self.queueCancellationPolicy = configuration.queueCancellationPolicy
        self.eventDispatcher = eventDispatcher
        self.telemetrySink = telemetrySink
        self.middlewareRegistry = middlewareRegistry
        self.broadcaster = broadcaster
        self.traceLogger = configuration.logger
        self.traceRecorder = nil
        updateEffectiveTraceRecorder()
    }

    // Telemetry adapter helpers live in
    // `ModalStore+TelemetryAdapters.swift` so this file stays
    // focused on the `Observable` storage and execution surface.

    func installTraceRecorder(_ recorder: InternalExecutionTraceRecorder?) {
        self.traceRecorder = recorder
        updateEffectiveTraceRecorder()
    }

    func performAfterObservationDelivery(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        eventDispatcher.performAfterDelivery(action)
    }

    private func updateEffectiveTraceRecorder() {
        if traceRecorder == nil && traceLogger == nil {
            cachedEffectiveTraceRecorder = nil
            return
        }

        cachedEffectiveTraceRecorder = { [weak self] record in
            self?.traceRecorder?(record)
            self?.logTraceRecord(record)
        }
    }

    private var effectiveTraceRecorder: InternalExecutionTraceRecorder? {
        cachedEffectiveTraceRecorder
    }

    private func logTraceRecord(_ record: InternalExecutionTraceRecord) {
        guard let traceLogger else { return }

        switch record {
        case .start(let context, let operation, let metadata):
            let metadataSummary = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            traceLogger.debug(
                """
                modal trace start \
                root=\(context.rootID, privacy: .public) \
                span=\(context.spanID, privacy: .public) \
                parent=\(context.parentSpanID ?? "nil", privacy: .public) \
                operation=\(operation, privacy: .public) \
                metadata=\(metadataSummary, privacy: .private)
                """
            )

        case .finish(let context, let operation, let outcome):
            traceLogger.debug(
                """
                modal trace finish \
                root=\(context.rootID, privacy: .public) \
                span=\(context.spanID, privacy: .public) \
                parent=\(context.parentSpanID ?? "nil", privacy: .public) \
                operation=\(operation, privacy: .public) \
                outcome=\(outcome, privacy: .private)
                """
            )
        }
    }

    // MARK: - Public middleware API

    // Note: middleware CRUD (add/insert/remove/replace/move) lives
    // in `ModalStore+Middleware.swift`.

    // MARK: - Public command API

    public func send(_ intent: ModalIntent<M>) {
        switch intent {
        case .present(let route, let style):
            present(route, style: style)
        case .dismiss:
            dismissCurrent()
        case .dismissAll:
            dismissAll()
        }
    }

    @discardableResult
    public func execute(_ command: ModalCommand<M>) -> ModalExecutionResult<M> {
        eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
            domain: .modal,
            operation: "execute",
            recorder: effectiveTraceRecorder,
            metadata: ["command": String(describing: command)]
        ) {
            let outcome = middlewareRegistry.intercept(
                command,
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            )

            switch outcome.interception {
            case .cancel(let reason):
                let result: ModalExecutionResult<M> = .cancelled(reason)

                // Apply the configured queue cancellation policy
                // before the post-execute hooks so observers see
                // the resulting queue state.
                applyQueueCancellationPolicy(
                    command: outcome.command,
                    reason: reason
                )

                middlewareRegistry.didExecute(
                    outcome.command,
                    currentPresentation: currentPresentation,
                    queuedPresentations: queuedPresentations,
                    participants: outcome.participants
                )
                telemetrySink.recordCommandIntercepted(
                    command: outcome.command,
                    outcome: .cancelled,
                    cancellationReason: reason
                )
                return result

            case .proceed(let effectiveCommand):
                let result = applyCommand(effectiveCommand)

                middlewareRegistry.didExecute(
                    effectiveCommand,
                    currentPresentation: currentPresentation,
                    queuedPresentations: queuedPresentations,
                    participants: outcome.participants
                )

                telemetrySink.recordCommandIntercepted(
                    command: effectiveCommand,
                    outcome: Self.outcomeKind(for: result),
                    cancellationReason: nil
                )
                return result
            }
            } outcome: { result in
                String(describing: result)
            }
        }
    }

    /// Presents a route and reports whether it became the active modal,
    /// was deferred behind an already-active one, or was rewritten by
    /// middleware into a non-presentation command.
    ///
    /// The returned identifier reflects the effective presentation after
    /// middleware rewrites. Callers that branch on the outcome can pattern-
    /// match ``ModalPresentResult`` instead of inspecting arbitrary
    /// ``ModalExecutionResult`` payloads.
    @discardableResult
    public func present(_ route: M, style: ModalPresentationStyle) -> ModalPresentResult<M> {
        let presentation = ModalPresentation(route: route, style: style)
        let result = execute(.present(presentation))
        return Self.presentResult(from: result)
    }

    private static func presentResult(
        from result: ModalExecutionResult<M>
    ) -> ModalPresentResult<M> {
        switch result {
        case .executed(let command):
            switch command {
            case .present(let presentation),
                 .replaceCurrent(let presentation):
                return .shownImmediately(id: presentation.id)
            case .dismissCurrent, .dismissAll:
                return .rewrittenWithoutPresentation(command: command)
            }
        case .queued(let queued):
            return .queuedBehind(id: queued.id)
        case .cancelled(let reason):
            return .cancelled(reason)
        case .noop:
            return .noop
        }
    }

    public func replaceCurrent(_ route: M, style: ModalPresentationStyle) {
        let replacement: ModalPresentation<M>
        if let currentPresentation {
            replacement = ModalPresentation(
                id: currentPresentation.id,
                route: route,
                style: style
            )
        } else {
            replacement = ModalPresentation(route: route, style: style)
        }
        _ = execute(.replaceCurrent(replacement))
    }

    public func dismissCurrent() {
        dismissCurrent(reason: .dismiss)
    }

    func dismissCurrent(reason: ModalDismissalReason) {
        _ = execute(.dismissCurrent(reason: reason))
    }

    public func dismissAll() {
        _ = execute(.dismissAll)
    }

    var flowStateSnapshot: ModalExecutionState<M> {
        Self.makeSnapshot(
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
            let stateAfter = cancellationState(
                command: outcome.command,
                reason: reason,
                from: stateBefore
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
            let previewOutcome = previewApplyCommand(effectiveCommand, to: stateBefore)
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
