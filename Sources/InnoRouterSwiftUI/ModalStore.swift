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
    public private(set) var currentPresentation: ModalPresentation<M>?
    public private(set) var queuedPresentations: [ModalPresentation<M>] = []
    private let queueCancellationPolicy: ModalQueueCancellationPolicy<M>
    private let eventDispatcher: SerializedEventDispatcher<ModalObservationDelivery<M>>
    private let telemetrySink: ModalStoreTelemetrySink<M>
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

    // MARK: - Command application (post-interception)

    private func applyCommand(_ command: ModalCommand<M>) -> ModalExecutionResult<M> {
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

    private func previewApplyCommand(
        _ command: ModalCommand<M>,
        to snapshot: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        switch command {
        case .present(let presentation):
            return previewPresent(presentation, on: snapshot)
        case .replaceCurrent(let presentation):
            return previewReplaceCurrent(presentation, on: snapshot)
        case .dismissCurrent(let reason):
            return previewDismissCurrent(reason: reason, on: snapshot)
        case .dismissAll:
            return previewDismissAll(on: snapshot)
        }
    }

    private func previewPresent(
        _ presentation: ModalPresentation<M>,
        on snapshot: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        if snapshot.currentPresentation == nil {
            return (
                .executed(.present(presentation)),
                Self.makeSnapshot(
                    currentPresentation: presentation,
                    queuedPresentations: snapshot.queuedPresentations
                )
            )
        }

        return (
            .queued(presentation),
            Self.makeSnapshot(
                currentPresentation: snapshot.currentPresentation,
                queuedPresentations: snapshot.queuedPresentations + [presentation]
            )
        )
    }

    private func previewDismissCurrent(
        reason: ModalDismissalReason,
        on snapshot: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        guard snapshot.currentPresentation != nil else {
            return (.noop, snapshot)
        }

        let nextPresentation = snapshot.queuedPresentations.first
        let remainingQueue = nextPresentation == nil
            ? snapshot.queuedPresentations
            : Array(snapshot.queuedPresentations.dropFirst())

        return (
            .executed(.dismissCurrent(reason: reason)),
            Self.makeSnapshot(
                currentPresentation: nextPresentation,
                queuedPresentations: remainingQueue
            )
        )
    }

    private func previewDismissAll(
        on snapshot: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        guard snapshot.currentPresentation != nil || !snapshot.queuedPresentations.isEmpty else {
            return (.noop, snapshot)
        }

        return (
            .executed(.dismissAll),
            Self.makeSnapshot(currentPresentation: nil, queuedPresentations: [])
        )
    }

    private func previewReplaceCurrent(
        _ presentation: ModalPresentation<M>,
        on snapshot: ModalExecutionState<M>
    ) -> (result: ModalExecutionResult<M>, stateAfter: ModalExecutionState<M>) {
        guard let currentPresentation = snapshot.currentPresentation else {
            return (.noop, snapshot)
        }

        guard currentPresentation != presentation else {
            return (.noop, snapshot)
        }

        return (
            .executed(.replaceCurrent(presentation)),
            Self.makeSnapshot(
                currentPresentation: presentation,
                queuedPresentations: snapshot.queuedPresentations
            )
        )
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
    private func applyQueueCancellationPolicy(
        command: ModalCommand<M>,
        reason: ModalCancellationReason<M>
    ) {
        let stateBefore = flowStateSnapshot
        let stateAfter = cancellationState(
            command: command,
            reason: reason,
            from: stateBefore
        )
        guard stateAfter != stateBefore else { return }

        currentPresentation = stateAfter.currentPresentation
        queuedPresentations = stateAfter.queuedPresentations
        telemetrySink.recordQueueChanged(
            oldQueue: stateBefore.queuedPresentations,
            newQueue: stateAfter.queuedPresentations
        )
    }

    /// Applies cancellation policy to a preview snapshot without mutating the
    /// live store. FlowStore uses this to keep preview and direct execution
    /// semantics aligned while preserving atomic reset rollback.
    private func cancellationState(
        command: ModalCommand<M>,
        reason: ModalCancellationReason<M>,
        from snapshot: ModalExecutionState<M>
    ) -> ModalExecutionState<M> {
        guard !snapshot.queuedPresentations.isEmpty else { return snapshot }

        switch queueCancellationPolicy.resolve(command: command, reason: reason) {
        case .preserve:
            return snapshot
        case .dropQueued:
            return Self.makeSnapshot(
                currentPresentation: snapshot.currentPresentation,
                queuedPresentations: []
            )
        }
    }

    private func emitCommittedEvents(for preview: ModalExecutionJournal<M>) {
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

    private static func makeSnapshot(
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) -> ModalExecutionState<M> {
        let normalized = normalize(
            currentPresentation: currentPresentation,
            queuedPresentations: queuedPresentations
        )
        return ModalExecutionState(
            currentPresentation: normalized.current,
            queuedPresentations: normalized.queue
        )
    }

    private static func outcomeKind(
        for result: ModalExecutionResult<M>
    ) -> ModalStoreTelemetryEvent<M>.InterceptionOutcomeKind {
        switch result {
        case .executed: return .executed
        case .queued: return .queued
        case .cancelled: return .cancelled
        case .noop: return .noop
        }
    }

    private static func normalize(
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) -> (current: ModalPresentation<M>?, queue: [ModalPresentation<M>]) {
        guard currentPresentation == nil, let firstQueued = queuedPresentations.first else {
            return (currentPresentation, queuedPresentations)
        }

        return (firstQueued, Array(queuedPresentations.dropFirst()))
    }
}
