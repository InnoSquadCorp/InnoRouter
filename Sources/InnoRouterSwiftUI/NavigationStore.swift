import OSLog
import InnoRouterCore
import Observation
import SwiftUI

struct NavigationObservationDelivery<R: Route> {
    let event: NavigationEvent<R>
    let telemetryEvent: NavigationStoreTelemetryEvent<R>?
}

@Observable
@MainActor
public final class NavigationStore<R: Route>: Navigator, NavigationBatchExecutor, NavigationTransactionExecutor {
    public typealias RouteType = R

    public private(set) var state: RouteStack<R>

    internal let eventDispatcher: SerializedEventDispatcher<NavigationObservationDelivery<R>>
    internal let telemetrySink: NavigationStoreTelemetrySink<R>
    // `middlewareRegistry` is `internal` rather than `private`
    // because middleware management methods live in
    // `NavigationStore+Middleware.swift`.
    internal let middlewareRegistry: NavigationMiddlewareRegistry<R>
    internal let executionCoordinator: NavigationExecutionCoordinator<R>
    private let routeStackValidator: RouteStackValidator<R>
    internal let pathMismatchPolicy: NavigationPathMismatchPolicy<R>
    internal let pathMismatchAssertionHandler: @MainActor @Sendable ([R], [R]) -> Void
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
    /// Hosts publish this through their unified router authority so descendants
    /// can use ``EnvironmentRouter`` without holding a direct store reference.
    /// The dispatcher is created on first access and reused for the lifetime of
    /// the store, so a SwiftUI host does not allocate a fresh closure on every
    /// render.
    var intentDispatcher: NavigationIntentHandler<R> {
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
        let wiring = Self.makeObservationWiring(
            configuration: configuration,
            telemetryRecorder: nil
        )
        self.state = initial
        self.eventDispatcher = wiring.eventDispatcher
        self.routeStackValidator = configuration.routeStackValidator
        self.pathMismatchPolicy = configuration.pathMismatchPolicy
        self.pathMismatchAssertionHandler = Self.defaultPathMismatchAssertionHandler
        self.telemetrySink = wiring.telemetrySink
        self.middlewareRegistry = wiring.middlewareRegistry
        self.executionCoordinator = NavigationExecutionCoordinator(
            middlewareRegistry: wiring.middlewareRegistry
        )
        self.broadcaster = wiring.broadcaster
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
        let wiring = Self.makeObservationWiring(
            configuration: configuration,
            telemetryRecorder: telemetryRecorder
        )
        self.state = initial
        self.eventDispatcher = wiring.eventDispatcher
        self.routeStackValidator = configuration.routeStackValidator
        self.pathMismatchPolicy = configuration.pathMismatchPolicy
        self.pathMismatchAssertionHandler = nonPrefixAssertionHandler
        self.telemetrySink = wiring.telemetrySink
        self.middlewareRegistry = wiring.middlewareRegistry
        self.executionCoordinator = NavigationExecutionCoordinator(
            middlewareRegistry: wiring.middlewareRegistry
        )
        self.broadcaster = wiring.broadcaster
        self.traceLogger = configuration.logger
        self.traceRecorder = nil
        self.cachedEffectiveTraceRecorder = nil
        updateEffectiveTraceRecorder()
    }

    /// Shared observation plumbing for both initializers: broadcaster,
    /// serialized dispatcher, telemetry sink, and middleware registry.
    /// The test-only `telemetryRecorder` hook is a no-op when `nil`, so
    /// the public initializer funnels through the identical wiring.
    private struct ObservationWiring {
        let eventDispatcher: SerializedEventDispatcher<NavigationObservationDelivery<R>>
        let telemetrySink: NavigationStoreTelemetrySink<R>
        let middlewareRegistry: NavigationMiddlewareRegistry<R>
        let broadcaster: EventBroadcaster<NavigationEvent<R>>
    }

    private static func makeObservationWiring(
        configuration: NavigationStoreConfiguration<R>,
        telemetryRecorder: NavigationStoreTelemetryRecorder<R>?
    ) -> ObservationWiring {
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
        return ObservationWiring(
            eventDispatcher: eventDispatcher,
            telemetrySink: telemetrySink,
            middlewareRegistry: middlewareRegistry,
            broadcaster: broadcaster
        )
    }

    // Telemetry adapter helpers live in
    // `NavigationStore+TelemetryAdapters.swift` so this file stays
    // focused on the `Observable` storage and execution surface.

    func installTraceRecorder(_ recorder: InternalExecutionTraceRecorder?) {
        self.traceRecorder = recorder
        updateEffectiveTraceRecorder()
    }

    /// Re-applies the store's one-shot route-stack policy at restoration
    /// boundaries without changing normal command execution semantics.
    func validateRestoredPath(_ path: [R]) throws {
        try routeStackValidator.validate(path)
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

    var effectiveTraceRecorder: InternalExecutionTraceRecorder? {
        cachedEffectiveTraceRecorder
    }

    private func logTraceRecord(_ record: InternalExecutionTraceRecord) {
        traceLogger?.logExecutionTrace(record, label: "navigation")
    }

    func assignState(_ newState: RouteStack<R>) {
        state = newState
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
}
