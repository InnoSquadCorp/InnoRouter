import OSLog

import InnoRouterCore

/// Internal OSLog recorder for canonical navigation observation events.
struct OSLogNavigationTelemetrySink<R: Route> {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func record(_ event: NavigationEvent<R>) {
        logger.notice(
            """
            navigation telemetry \
            event=\(Self.kind(for: event), privacy: .public) \
            summary=\(String(describing: event), privacy: .private(mask: .hash))
            """
        )
    }

    private static func kind(for event: NavigationEvent<R>) -> String {
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

/// Internal OSLog recorder for canonical modal observation events.
struct OSLogModalTelemetrySink<M: Route> {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func record(_ event: ModalEvent<M>) {
        logger.notice(
            """
            modal telemetry \
            event=\(Self.kind(for: event), privacy: .public) \
            summary=\(String(describing: event), privacy: .private(mask: .hash))
            """
        )
    }

    private static func kind(for event: ModalEvent<M>) -> String {
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
