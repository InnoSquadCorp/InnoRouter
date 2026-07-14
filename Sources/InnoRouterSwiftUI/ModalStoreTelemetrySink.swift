// MARK: - Design note: why two separate TelemetrySinks?
//
// See the matching note at the top of
// `NavigationStoreTelemetrySink.swift`. Short version: a generic
// `TelemetrySink<Event>` can't preserve OSLog's compile-time
// `privacy:` interpolation marks, and the two sinks have genuinely
// different record-method surfaces (Nav: 2 methods, Modal: 6) that
// would fight any attempt at unification. Investigated and declined
// during the PR #21 follow-up pass.

import OSLog

import InnoRouterCore

@MainActor
final class ModalStoreTelemetrySink<M: Route> {
    private let logger: Logger?
    private let recorder: ModalStoreTelemetryRecorder<M>?

    init(
        logger: Logger?,
        recorder: ModalStoreTelemetryRecorder<M>? = nil
    ) {
        self.logger = logger
        self.recorder = recorder
    }

    func recordPresented(_ presentation: ModalPresentation<M>) {
        recorder?(.presented(presentation))

        guard let logger else { return }
        logger.notice(
            """
            modal presented \
            id=\(presentation.id.uuidString, privacy: .private) \
            route=\(Self.routeSummary(for: presentation.route), privacy: .private(mask: .hash)) \
            style=\(String(describing: presentation.style), privacy: .public)
            """
        )
    }

    func recordDismissed(
        _ presentation: ModalPresentation<M>,
        reason: ModalDismissalReason
    ) {
        recorder?(.dismissed(presentation, reason: reason))

        guard let logger else { return }
        logger.notice(
            """
            modal dismissed \
            id=\(presentation.id.uuidString, privacy: .private) \
            route=\(Self.routeSummary(for: presentation.route), privacy: .private(mask: .hash)) \
            style=\(String(describing: presentation.style), privacy: .public) \
            reason=\(String(describing: reason), privacy: .private(mask: .hash))
            """
        )
    }

    func recordReplaced(
        old oldPresentation: ModalPresentation<M>,
        new newPresentation: ModalPresentation<M>
    ) {
        recorder?(.replaced(old: oldPresentation, new: newPresentation))

        guard let logger else { return }
        logger.notice(
            """
            modal replaced \
            oldID=\(oldPresentation.id.uuidString, privacy: .private) \
            newID=\(newPresentation.id.uuidString, privacy: .private) \
            oldRoute=\(Self.routeSummary(for: oldPresentation.route), privacy: .private(mask: .hash)) \
            newRoute=\(Self.routeSummary(for: newPresentation.route), privacy: .private(mask: .hash)) \
            style=\(String(describing: newPresentation.style), privacy: .public)
            """
        )
    }

    func recordQueued(_ presentation: ModalPresentation<M>) {
        recorder?(.queued(presentation))

        guard let logger else { return }
        logger.notice(
            """
            modal queued \
            id=\(presentation.id.uuidString, privacy: .private) \
            route=\(Self.routeSummary(for: presentation.route), privacy: .private(mask: .hash)) \
            style=\(String(describing: presentation.style), privacy: .public)
            """
        )
    }

    func recordQueueChanged(
        oldQueue: [ModalPresentation<M>],
        newQueue: [ModalPresentation<M>]
    ) {
        recorder?(.queueChanged(oldQueue: oldQueue, newQueue: newQueue))

        guard let logger else { return }
        logger.notice(
            """
            modal queue changed \
            oldCount=\(String(oldQueue.count), privacy: .public) \
            newCount=\(String(newQueue.count), privacy: .public)
            """
        )
    }

    func recordMiddlewareMutation(
        _ action: ModalStoreTelemetryEvent<M>.MiddlewareMutation,
        metadata: ModalMiddlewareMetadata,
        index: Int?
    ) {
        recorder?(
            .middlewareMutation(action: action, metadata: metadata, index: index)
        )

        guard let logger else { return }
        logger.notice(
            """
            modal middleware mutation \
            action=\(action.rawValue, privacy: .public) \
            handle=\(metadata.handle.logValue, privacy: .public) \
            debugName=\(metadata.debugName ?? "nil", privacy: .private(mask: .hash)) \
            index=\(String(index ?? -1), privacy: .public)
            """
        )
    }

    func recordCommandIntercepted(
        command: ModalCommand<M>,
        outcome: ModalStoreTelemetryEvent<M>.InterceptionOutcomeKind,
        cancellationReason: ModalCancellationReason<M>?
    ) {
        recorder?(
            .commandIntercepted(
                command: command,
                outcome: outcome,
                cancellationReason: cancellationReason
            )
        )

        guard let logger else { return }
        logger.notice(
            """
            modal command intercepted \
            command=\(Self.commandSummary(for: command), privacy: .private(mask: .hash)) \
            outcome=\(outcome.rawValue, privacy: .public) \
            cancellation=\(cancellationReason.map { String(describing: $0) } ?? "nil", privacy: .private)
            """
        )
    }

    private static func commandSummary(for command: ModalCommand<M>) -> String {
        switch command {
        case .present(let presentation):
            return "present(\(routeSummary(for: presentation.route)), \(presentation.style))"
        case .replaceCurrent(let presentation):
            return "replaceCurrent(\(routeSummary(for: presentation.route)), \(presentation.style))"
        case .dismissCurrent(let reason):
            return "dismissCurrent(\(reason))"
        case .dismissAll:
            return "dismissAll"
        }
    }

    private static func routeSummary(for route: M) -> String {
        let description = String(describing: route)
        return description
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? description
    }
}
