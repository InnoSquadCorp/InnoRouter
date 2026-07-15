import OSLog
import InnoRouterCore
import Observation
import SwiftUI

private struct NavigationObservationDelivery<R: Route> {
    let event: NavigationEvent<R>
    let telemetryEvent: NavigationStoreTelemetryEvent<R>?
}

@Observable
@MainActor
public final class NavigationStore<R: Route>: Navigator, NavigationBatchExecutor, NavigationTransactionExecutor {
    public typealias RouteType = R

    public private(set) var state: RouteStack<R>

    private let engine: NavigationEngine<R>
    private let eventDispatcher: SerializedEventDispatcher<NavigationObservationDelivery<R>>
    private let telemetrySink: NavigationStoreTelemetrySink<R>
    // `middlewareRegistry` is `internal` rather than `private`
    // because middleware management methods live in
    // `NavigationStore+Middleware.swift`.
    internal let middlewareRegistry: NavigationMiddlewareRegistry<R>
    // Reconciler is type-erased to the protocol so callers can
    // inject their own conformance via
    // `NavigationStoreConfiguration.pathReconciler`.
    private let pathReconciler: any NavigationPathReconciling<R>
    private let pathMismatchPolicy: NavigationPathMismatchPolicy<R>
    private let pathMismatchAssertionHandler: @MainActor @Sendable ([R], [R]) -> Void
    private let broadcaster: EventBroadcaster<NavigationEvent<R>>
    private let traceLogger: Logger?
    private var traceRecorder: InternalExecutionTraceRecorder?
    private var cachedEffectiveTraceRecorder: InternalExecutionTraceRecorder?
    /// Cached intent closure that lives for the lifetime of this store.
    /// Built on first access by ``intentDispatcher`` so SwiftUI hosts do
    /// not allocate a fresh closure on every render.
    @ObservationIgnored
    private var cachedIntentDispatcher: NavigationIntentHandler<R>?

    /// A closure that forwards `NavigationIntent` values to this store's
    /// ``send(_:)`` entry point.
    ///
    /// Hosts publish this through the SwiftUI environment so descendants can
    /// use ``EnvironmentNavigationIntent`` to dispatch view-layer intents
    /// without holding a direct store reference. The dispatcher is created
    /// on first access and reused for the lifetime of the store, so a
    /// SwiftUI host does not allocate a fresh closure on every render.
    public var intentDispatcher: @MainActor @Sendable (NavigationIntent<R>) -> Void {
        if let cachedIntentDispatcher {
            return cachedIntentDispatcher
        }
        let dispatcher: NavigationIntentHandler<R> = { [weak self] intent in
            self?.send(intent)
        }
        cachedIntentDispatcher = dispatcher
        return dispatcher
    }

    /// Ordered snapshot of the registered middleware identities and debug labels.
    public var middlewareMetadata: [NavigationMiddlewareMetadata] {
        middlewareRegistry.metadata
    }

    /// A multicast `AsyncStream` that emits every observation event the
    /// store produces — stack changes, batch / transaction completions,
    /// middleware mutations, and path-mismatch resolutions — in the
    /// same order as the synchronous
    /// ``NavigationStoreConfiguration/onEvent`` callback.
    ///
    /// Each call to `events` returns a fresh stream with its own
    /// continuation; multiple subscribers see every event
    /// independently. When a subscriber cancels its iterator (or the
    /// store deallocates) its continuation is cleaned up automatically.
    public var events: AsyncStream<NavigationEvent<R>> {
        broadcaster.stream()
    }

    public init(
        initial: RouteStack<R> = .init(),
        configuration: NavigationStoreConfiguration<R> = .init()
    ) {
        let broadcaster = EventBroadcaster<NavigationEvent<R>>(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        let observationTelemetrySink = Self.defaultTelemetrySink(for: configuration)
        let onEvent = configuration.onEvent
        let eventDispatcher = SerializedEventDispatcher<NavigationObservationDelivery<R>> { delivery in
            onEvent?(delivery.event)
            observationTelemetrySink?.record(delivery.event)
            broadcaster.broadcast(delivery.event)
        }
        let telemetrySink = NavigationStoreTelemetrySink<R>(
            logger: nil,
            recorder: { telemetryEvent in
                eventDispatcher.emit(
                    NavigationObservationDelivery(
                        event: Self.publicEvent(for: telemetryEvent),
                        telemetryEvent: telemetryEvent
                    )
                )
            }
        )
        let middlewareRegistry = NavigationMiddlewareRegistry(
            registrations: configuration.middlewares,
            telemetrySink: telemetrySink
        )
        self.state = initial
        self.engine = .init()
        self.eventDispatcher = eventDispatcher
        self.pathMismatchPolicy = configuration.pathMismatchPolicy
        self.pathMismatchAssertionHandler = Self.defaultPathMismatchAssertionHandler
        self.telemetrySink = telemetrySink
        self.middlewareRegistry = middlewareRegistry
        self.pathReconciler = configuration.pathReconciler
        self.broadcaster = broadcaster
        self.traceLogger = configuration.logger
        self.traceRecorder = nil
        self.cachedEffectiveTraceRecorder = nil
        updateEffectiveTraceRecorder()
    }

    public convenience init(
        initialPath: [R],
        configuration: NavigationStoreConfiguration<R> = .init()
    ) throws {
        let initial = try RouteStack(validating: initialPath, using: configuration.routeStackValidator)
        self.init(initial: initial, configuration: configuration)
    }

    init(
        initial: RouteStack<R> = .init(),
        configuration: NavigationStoreConfiguration<R> = .init(),
        nonPrefixAssertionHandler: @escaping @MainActor @Sendable ([R], [R]) -> Void,
        telemetryRecorder: NavigationStoreTelemetryRecorder<R>? = nil
    ) {
        let broadcaster = EventBroadcaster<NavigationEvent<R>>(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        let observationTelemetrySink = Self.defaultTelemetrySink(for: configuration)
        let onEvent = configuration.onEvent
        let eventDispatcher = SerializedEventDispatcher<NavigationObservationDelivery<R>> { delivery in
            onEvent?(delivery.event)
            if let telemetryEvent = delivery.telemetryEvent {
                telemetryRecorder?(telemetryEvent)
            }
            observationTelemetrySink?.record(delivery.event)
            broadcaster.broadcast(delivery.event)
        }
        let telemetrySink = NavigationStoreTelemetrySink(
            logger: nil,
            recorder: { telemetryEvent in
                eventDispatcher.emit(
                    NavigationObservationDelivery(
                        event: Self.publicEvent(for: telemetryEvent),
                        telemetryEvent: telemetryEvent
                    )
                )
            }
        )
        let middlewareRegistry = NavigationMiddlewareRegistry(
            registrations: configuration.middlewares,
            telemetrySink: telemetrySink
        )
        self.state = initial
        self.engine = .init()
        self.eventDispatcher = eventDispatcher
        self.pathMismatchPolicy = configuration.pathMismatchPolicy
        self.pathMismatchAssertionHandler = nonPrefixAssertionHandler
        self.telemetrySink = telemetrySink
        self.middlewareRegistry = middlewareRegistry
        self.pathReconciler = configuration.pathReconciler
        self.broadcaster = broadcaster
        self.traceLogger = configuration.logger
        self.traceRecorder = nil
        self.cachedEffectiveTraceRecorder = nil
        updateEffectiveTraceRecorder()
    }

    // Telemetry adapter helpers live in
    // `NavigationStore+TelemetryAdapters.swift` so this file stays
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
                navigation trace start \
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
                navigation trace finish \
                root=\(context.rootID, privacy: .public) \
                span=\(context.spanID, privacy: .public) \
                parent=\(context.parentSpanID ?? "nil", privacy: .public) \
                operation=\(operation, privacy: .public) \
                outcome=\(outcome, privacy: .private)
                """
            )
        }
    }

    // Note: middleware CRUD (add/insert/remove/replace/move) lives
    // in `NavigationStore+Middleware.swift`.

    @discardableResult
    public func execute(_ command: NavigationCommand<R>) -> NavigationResult<R> {
        eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "execute",
                recorder: effectiveTraceRecorder,
                metadata: ["command": String(describing: command)]
            ) {
                executeSingle(command, shouldNotifyOnChange: true).result
            } outcome: { result in
                String(describing: result)
            }
        }
    }

    @discardableResult
    public func executeBatch(
        _ commands: [NavigationCommand<R>],
        stopOnFailure: Bool = false
    ) -> NavigationBatchResult<R> {
        eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "executeBatch",
                recorder: effectiveTraceRecorder,
                metadata: [
                    "count": String(commands.count),
                    "stopOnFailure": String(stopOnFailure),
                ]
            ) {
                let stateBefore = state
                var executedCommands: [NavigationCommand<R>] = []
                executedCommands.reserveCapacity(commands.count)
                var results: [NavigationResult<R>] = []
                results.reserveCapacity(commands.count)
                var hasStoppedOnFailure = false

                for command in commands {
                    let outcome = executeSingle(command, shouldNotifyOnChange: false)
                    executedCommands.append(contentsOf: outcome.executedCommands)
                    results.append(outcome.result)

                    if stopOnFailure && !outcome.result.isSuccess {
                        hasStoppedOnFailure = true
                        break
                    }
                }

                let stateAfter = state
                if stateAfter != stateBefore {
                    emitObservationEvent(.changed(from: stateBefore, to: stateAfter))
                }

                let batch = NavigationBatchResult(
                    requestedCommands: commands,
                    executedCommands: executedCommands,
                    results: results,
                    stateBefore: stateBefore,
                    stateAfter: stateAfter,
                    hasStoppedOnFailure: hasStoppedOnFailure
                )
                emitObservationEvent(.batchExecuted(batch))
                return batch
            } outcome: { batch in
                batch.isSuccess ? "success" : "failure"
            }
        }
    }

    @discardableResult
    public func executeTransaction(
        _ commands: [NavigationCommand<R>]
    ) -> NavigationTransactionResult<R> {
        eventDispatcher.withExecutionBoundary {
            InternalExecutionTrace.withSpan(
                domain: .navigation,
                operation: "executeTransaction",
                recorder: effectiveTraceRecorder,
                metadata: ["count": String(commands.count)]
            ) {
                let stateBefore = state
                var shadowState = state
                var journals: [NavigationExecutionJournal<R>] = []
                journals.reserveCapacity(commands.count)
                var failureIndex: Int?

                for (index, command) in commands.enumerated() {
                    let journal = NavigationExecutionJournal.planTransaction(
                        command,
                        state: &shadowState,
                        middlewareRegistry: middlewareRegistry,
                        engine: engine
                    )
                    journals.append(journal)

                    if journal.result.isSuccess {
                        continue
                    } else {
                        failureIndex = index
                        break
                    }
                }

                let isCommitted = !commands.isEmpty && failureIndex == nil
                let executedCommands = journals.flatMap(\.executedCommands)
                let results: [NavigationResult<R>]
                if isCommitted {
                    state = shadowState
                    results = journals.map { $0.finalizeCommittedTransaction(using: middlewareRegistry) }
                    if state != stateBefore {
                        emitObservationEvent(.changed(from: stateBefore, to: state))
                    }
                } else {
                    journals
                        .map { $0.forDiscardedTransaction() }
                        .forEach { $0.discardExecuted(using: middlewareRegistry) }
                    results = journals.map(\.result)
                }

                let transaction = NavigationTransactionResult(
                    requestedCommands: commands,
                    executedCommands: executedCommands,
                    results: results,
                    stateBefore: stateBefore,
                    stateAfter: isCommitted ? state : stateBefore,
                    failureIndex: failureIndex,
                    isCommitted: isCommitted
                )
                emitObservationEvent(.transactionExecuted(transaction))
                return transaction
            } outcome: { transaction in
                if commands.isEmpty {
                    "empty"
                } else {
                    transaction.isCommitted ? "committed" : "rolledBack"
                }
            }
        }
    }

    // Note: send(_:) and commands(for:) live in
    // `NavigationStore+Intent.swift`.

    // Note: pathBinding, pathBinding(policy:), and binding(case:)
    // live in `NavigationStore+Binding.swift`.

    func previewFlowCommand(_ command: NavigationCommand<R>) -> NavigationExecutionJournal<R> {
        previewFlowCommand(command, from: state)
    }

    func previewFlowCommand(
        _ command: NavigationCommand<R>,
        from stateBefore: RouteStack<R>
    ) -> NavigationExecutionJournal<R> {
        NavigationExecutionJournal.preview(
            command,
            from: stateBefore,
            middlewareRegistry: middlewareRegistry,
            engine: engine
        )
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
                state = preview.stateAfter

                let finalResult = preview.finalizePreview(using: middlewareRegistry)

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
        preview
            .forDiscardedTransaction()
            .discardExecuted(using: middlewareRegistry)
    }

    // `reconcileNavigationPath` is `internal` rather than `private`
    // because the binding helpers live in
    // `NavigationStore+Binding.swift`. Access stays within the
    // InnoRouterSwiftUI module.
    internal func reconcileNavigationPath(
        with newPath: [R],
        policyOverride: NavigationPathMismatchPolicy<R>? = nil
    ) {
        eventDispatcher.withExecutionBoundary {
            pathReconciler.reconcile(
                from: state.path,
                to: newPath,
                resolveMismatch: { [weak self] oldPath, newPath in
                    guard let self else { return .single(.replace(newPath)) }
                    return self.resolvePathMismatch(
                        from: oldPath,
                        to: newPath,
                        policyOverride: policyOverride
                    )
                },
                execute: { [weak self] command in
                    guard let self else { return }
                    _ = self.execute(command)
                },
                executeBatch: { [weak self] commands in
                    guard let self else { return }
                    _ = self.executeBatch(commands, stopOnFailure: false)
                }
            )
        }
    }

    private func executeSingle(
        _ command: NavigationCommand<R>,
        shouldNotifyOnChange: Bool
    ) -> ExecutionOutcome {
        if shouldNotifyOnChange, case .sequence(let commands) = command {
            let outcomes = commands.map {
                executeSingle($0, shouldNotifyOnChange: true)
            }
            return ExecutionOutcome(
                executedCommands: outcomes.flatMap(\.executedCommands),
                result: .multiple(outcomes.map(\.result)),
                observationEvents: []
            )
        }

        let outcome = executeSingle(
            command,
            state: &state,
            shouldNotifyOnChange: shouldNotifyOnChange
        )
        for event in outcome.observationEvents {
            emitObservationEvent(event)
        }
        return outcome
    }

    private func executeSingle(
        _ command: NavigationCommand<R>,
        state currentState: inout RouteStack<R>,
        shouldNotifyOnChange: Bool
    ) -> ExecutionOutcome {
        switch command {
        case .sequence(let commands):
            let outcomes = commands.map {
                executeSingle($0, state: &currentState, shouldNotifyOnChange: shouldNotifyOnChange)
            }
            return ExecutionOutcome(
                executedCommands: outcomes.flatMap(\.executedCommands),
                result: .multiple(outcomes.map(\.result)),
                observationEvents: outcomes.flatMap(\.observationEvents)
            )

        case .whenCancelled(let primary, let fallback):
            let snapshot = currentState
            var primaryState = snapshot
            let primaryOutcome = executeSingle(
                primary,
                state: &primaryState,
                shouldNotifyOnChange: false
            )
            if primaryOutcome.result.isSuccess {
                currentState = primaryState
                return ExecutionOutcome(
                    executedCommands: primaryOutcome.executedCommands,
                    result: primaryOutcome.result,
                    observationEvents: Self.changeEvents(
                        from: snapshot,
                        to: currentState,
                        shouldNotify: shouldNotifyOnChange
                    )
                )
            }

            var fallbackState = snapshot
            let fallbackOutcome = executeSingle(
                fallback,
                state: &fallbackState,
                shouldNotifyOnChange: false
            )
            currentState = fallbackOutcome.result.isSuccess ? fallbackState : snapshot
            return ExecutionOutcome(
                executedCommands: primaryOutcome.executedCommands + fallbackOutcome.executedCommands,
                result: fallbackOutcome.result,
                observationEvents: Self.changeEvents(
                    from: snapshot,
                    to: currentState,
                    shouldNotify: shouldNotifyOnChange
                )
            )

        default:
            let stateBefore = currentState
            let interceptionOutcome = middlewareRegistry.intercept(command, state: stateBefore)
            switch interceptionOutcome.interception {
            case .cancel(let reason):
                let result: NavigationResult<R> = .cancelled(reason)
                return finishExecution(
                    command: interceptionOutcome.command,
                    executedCommands: [],
                    result: result,
                    participants: interceptionOutcome.participants,
                    stateBefore: stateBefore,
                    currentState: &currentState,
                    shouldNotifyOnChange: shouldNotifyOnChange
                )

            case .proceed(let commandToExecute):
                let result = engine.apply(commandToExecute, to: &currentState)
                return finishExecution(
                    command: commandToExecute,
                    executedCommands: [commandToExecute],
                    result: result,
                    participants: interceptionOutcome.participants,
                    stateBefore: stateBefore,
                    currentState: &currentState,
                    shouldNotifyOnChange: shouldNotifyOnChange
                )
            }
        }
    }

    private func finishExecution(
        command: NavigationCommand<R>,
        executedCommands: [NavigationCommand<R>],
        result: NavigationResult<R>,
        participants: [AnyNavigationMiddleware<R>],
        stateBefore: RouteStack<R>,
        currentState: inout RouteStack<R>,
        shouldNotifyOnChange: Bool
    ) -> ExecutionOutcome {
        let finalResult = middlewareRegistry.didExecute(
            command,
            result: result,
            state: currentState,
            participants: participants
        )

        return ExecutionOutcome(
            executedCommands: executedCommands,
            result: finalResult,
            observationEvents: Self.changeEvents(
                from: stateBefore,
                to: currentState,
                shouldNotify: shouldNotifyOnChange
            )
        )
    }

    private func resolvePathMismatch(
        from oldPath: [R],
        to newPath: [R],
        policyOverride: NavigationPathMismatchPolicy<R>? = nil
    ) -> NavigationPathMismatchResolution<R> {
        let policy: NavigationStoreTelemetryEvent<R>.PathMismatchPolicy
        let resolution: NavigationPathMismatchResolution<R>

        let effectivePolicy = policyOverride ?? pathMismatchPolicy
        switch effectivePolicy {
        case .replace:
            policy = .replace
            resolution = .single(.replace(newPath))

        case .assertAndReplace:
            policy = .assertAndReplace
            pathMismatchAssertionHandler(oldPath, newPath)
            resolution = .single(.replace(newPath))

        case .ignore:
            policy = .ignore
            resolution = .ignore

        case .custom(let transform):
            policy = .custom
            resolution = transform(oldPath, newPath)
        }

        telemetrySink.recordPathMismatch(
            policy: policy,
            resolution: resolution,
            oldPath: oldPath,
            newPath: newPath
        )
        return resolution
    }

    private static func changeEvents(
        from oldState: RouteStack<R>,
        to newState: RouteStack<R>,
        shouldNotify: Bool
    ) -> [NavigationEvent<R>] {
        guard shouldNotify, newState != oldState else { return [] }
        return [.changed(from: oldState, to: newState)]
    }

    private func emitObservationEvent(_ event: NavigationEvent<R>) {
        eventDispatcher.emit(
            NavigationObservationDelivery(
                event: event,
                telemetryEvent: nil
            )
        )
    }

    private static var defaultPathMismatchAssertionHandler: @MainActor @Sendable ([R], [R]) -> Void {
        { oldPath, newPath in
            assertionFailure(
                """
                Navigation path mismatch detected. \
                Falling back to replace.
                oldPath: \(String(describing: oldPath))
                newPath: \(String(describing: newPath))
                """
            )
        }
    }

    private struct ExecutionOutcome {
        let executedCommands: [NavigationCommand<R>]
        let result: NavigationResult<R>
        let observationEvents: [NavigationEvent<R>]
    }
}
