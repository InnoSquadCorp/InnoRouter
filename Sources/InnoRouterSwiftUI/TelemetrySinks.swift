import OSLog

import InnoRouterCore

/// Structured navigation telemetry emitted by ``NavigationStore``.
public typealias NavigationTelemetryEvent<R: Route> = NavigationEvent<R>

/// Structured modal telemetry emitted by ``ModalStore``.
public typealias ModalTelemetryEvent<M: Route> = ModalEvent<M>

/// Structured flow telemetry emitted by ``FlowStore``.
public typealias FlowTelemetryEvent<R: Route> = FlowEvent<R>

/// Receives structured navigation telemetry from a ``NavigationStore``.
@MainActor
public protocol NavigationTelemetrySink: Sendable {
    associatedtype RouteType: Route

    /// Records a single navigation telemetry event.
    func record(_ event: NavigationTelemetryEvent<RouteType>)
}

/// Receives structured modal telemetry from a ``ModalStore``.
@MainActor
public protocol ModalTelemetrySink: Sendable {
    associatedtype RouteType: Route

    /// Records a single modal telemetry event.
    func record(_ event: ModalTelemetryEvent<RouteType>)
}

/// Receives structured flow telemetry from a ``FlowStore``.
@MainActor
public protocol FlowTelemetrySink: Sendable {
    associatedtype RouteType: Route

    /// Records a single flow telemetry event.
    func record(_ event: FlowTelemetryEvent<RouteType>)
}

/// Type-erased navigation telemetry sink.
public struct AnyNavigationTelemetrySink<R: Route>: NavigationTelemetrySink {
    public typealias RouteType = R

    private let recordEvent: @MainActor @Sendable (NavigationTelemetryEvent<R>) -> Void

    /// Creates a sink from a recording closure.
    public init(record: @escaping @MainActor @Sendable (NavigationTelemetryEvent<R>) -> Void) {
        self.recordEvent = record
    }

    /// Erases a concrete navigation telemetry sink.
    public init<S: NavigationTelemetrySink>(_ sink: S) where S.RouteType == R {
        self.recordEvent = { event in
            sink.record(event)
        }
    }

    public func record(_ event: NavigationTelemetryEvent<R>) {
        recordEvent(event)
    }
}

/// Type-erased modal telemetry sink.
public struct AnyModalTelemetrySink<M: Route>: ModalTelemetrySink {
    public typealias RouteType = M

    private let recordEvent: @MainActor @Sendable (ModalTelemetryEvent<M>) -> Void

    /// Creates a sink from a recording closure.
    public init(record: @escaping @MainActor @Sendable (ModalTelemetryEvent<M>) -> Void) {
        self.recordEvent = record
    }

    /// Erases a concrete modal telemetry sink.
    public init<S: ModalTelemetrySink>(_ sink: S) where S.RouteType == M {
        self.recordEvent = { event in
            sink.record(event)
        }
    }

    public func record(_ event: ModalTelemetryEvent<M>) {
        recordEvent(event)
    }
}

/// Type-erased flow telemetry sink.
public struct AnyFlowTelemetrySink<R: Route>: FlowTelemetrySink {
    public typealias RouteType = R

    private let recordEvent: @MainActor @Sendable (FlowTelemetryEvent<R>) -> Void

    /// Creates a sink from a recording closure.
    public init(record: @escaping @MainActor @Sendable (FlowTelemetryEvent<R>) -> Void) {
        self.recordEvent = record
    }

    /// Erases a concrete flow telemetry sink.
    public init<S: FlowTelemetrySink>(_ sink: S) where S.RouteType == R {
        self.recordEvent = { event in
            sink.record(event)
        }
    }

    public func record(_ event: FlowTelemetryEvent<R>) {
        recordEvent(event)
    }
}

/// OSLog-backed navigation telemetry adapter.
public struct OSLogNavigationTelemetrySink<R: Route>: NavigationTelemetrySink {
    public typealias RouteType = R

    public let logger: Logger

    /// Creates an OSLog adapter using `logger`.
    public init(logger: Logger) {
        self.logger = logger
    }

    public func record(_ event: NavigationTelemetryEvent<R>) {
        logger.notice(
            """
            navigation telemetry \
            event=\(Self.kind(for: event), privacy: .public) \
            summary=\(String(describing: event), privacy: .private(mask: .hash))
            """
        )
    }

    private static func kind(for event: NavigationTelemetryEvent<R>) -> String {
        switch event {
        case .changed:
            return "changed"
        case .batchExecuted:
            return "batchExecuted"
        case .transactionExecuted:
            return "transactionExecuted"
        case .middlewareMutation:
            return "middlewareMutation"
        case .pathMismatch:
            return "pathMismatch"
        }
    }
}

/// OSLog-backed modal telemetry adapter.
public struct OSLogModalTelemetrySink<M: Route>: ModalTelemetrySink {
    public typealias RouteType = M

    public let logger: Logger

    /// Creates an OSLog adapter using `logger`.
    public init(logger: Logger) {
        self.logger = logger
    }

    public func record(_ event: ModalTelemetryEvent<M>) {
        logger.notice(
            """
            modal telemetry \
            event=\(Self.kind(for: event), privacy: .public) \
            summary=\(String(describing: event), privacy: .private(mask: .hash))
            """
        )
    }

    private static func kind(for event: ModalTelemetryEvent<M>) -> String {
        switch event {
        case .presented:
            return "presented"
        case .dismissed:
            return "dismissed"
        case .replaced:
            return "replaced"
        case .queueChanged:
            return "queueChanged"
        case .commandIntercepted:
            return "commandIntercepted"
        case .middlewareMutation:
            return "middlewareMutation"
        }
    }
}

/// OSLog-backed flow telemetry adapter.
public struct OSLogFlowTelemetrySink<R: Route>: FlowTelemetrySink {
    public typealias RouteType = R

    public let logger: Logger

    /// Creates an OSLog adapter using `logger`.
    public init(logger: Logger) {
        self.logger = logger
    }

    public func record(_ event: FlowTelemetryEvent<R>) {
        logger.notice(
            """
            flow telemetry \
            event=\(Self.kind(for: event), privacy: .public) \
            summary=\(String(describing: event), privacy: .private(mask: .hash))
            """
        )
    }

    private static func kind(for event: FlowTelemetryEvent<R>) -> String {
        switch event {
        case .pathChanged:
            return "pathChanged"
        case .intentRejected:
            return "intentRejected"
        case .navigation:
            return "navigation"
        case .modal:
            return "modal"
        }
    }
}
