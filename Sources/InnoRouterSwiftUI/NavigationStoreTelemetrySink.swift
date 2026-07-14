// MARK: - Design note: why two separate TelemetrySinks?
//
// Navigation and modal telemetry both fan out to `(logger, recorder)`,
// so a generic `TelemetrySink<Event>` has been considered. It was
// **investigated and declined** during the PR #21 follow-up pass.
// Unifying the two sinks would need one of:
//
//   (A) a `protocol TelemetryEvent { var logSummary: String { get } }`
//       → the runtime-formed `String` cannot reproduce OSLog's
//         compile-time `privacy: .public/.private` marks, so privacy
//         optimisation is lost.
//   (B) a closure formatter injected into `TelemetrySink<Event>`
//       → same privacy problem, plus runtime formatting cost.
//   (C) a protocol that only extracts common shape but keeps the two
//       sinks → +40 LOC with no actual duplication removed; the two
//       sinks have different numbers of record methods (Nav: 2,
//       Modal: 6) and the OSLog call per method is event-specific.
//
// Each sink therefore stays a hand-rolled `final class @MainActor`
// with bespoke `record*` methods tuned for OSLog's string-interpolation
// compile-time semantics. If a future consumer needs a common
// abstraction, reach for a reusable formatter helper rather than
// flattening the two record-method surfaces.

import OSLog

import InnoRouterCore

@MainActor
final class NavigationStoreTelemetrySink<R: Route> {
    private let logger: Logger?
    private let recorder: NavigationStoreTelemetryRecorder<R>?

    init(
        logger: Logger?,
        recorder: NavigationStoreTelemetryRecorder<R>? = nil
    ) {
        self.logger = logger
        self.recorder = recorder
    }

    func recordPathMismatch(
        policy: NavigationStoreTelemetryEvent<R>.PathMismatchPolicy,
        resolution: NavigationPathMismatchResolution<R>,
        oldPath: [R],
        newPath: [R]
    ) {
        let eventResolution = Self.makeTelemetryResolution(from: resolution)
        recorder?(
            .pathMismatch(
                policy: policy,
                resolution: eventResolution,
                oldPath: oldPath,
                newPath: newPath
            )
        )

        guard let logger else { return }
        logger.notice(
            """
            navigation path mismatch \
            policy=\(policy.rawValue, privacy: .public) \
            resolution=\(eventResolution.kind, privacy: .public) \
            oldPathCount=\(oldPath.count, privacy: .public) \
            oldPathSummary=\(Self.pathSummary(for: oldPath), privacy: .private(mask: .hash)) \
            newPathCount=\(newPath.count, privacy: .public) \
            newPathSummary=\(Self.pathSummary(for: newPath), privacy: .private(mask: .hash))
            """
        )
    }

    func recordMiddlewareMutation(
        _ action: NavigationStoreTelemetryEvent<R>.MiddlewareMutation,
        metadata: NavigationMiddlewareMetadata,
        index: Int?
    ) {
        recorder?(
            .middlewareMutation(action: action, metadata: metadata, index: index)
        )

        guard let logger else { return }
        logger.notice(
            """
            middleware mutation \
            action=\(action.rawValue, privacy: .public) \
            handle=\(metadata.handle.logValue, privacy: .public) \
            debugName=\(metadata.debugName ?? "nil", privacy: .private(mask: .hash)) \
            index=\(String(index ?? -1), privacy: .public)
            """
        )
    }

    private static func makeTelemetryResolution(
        from resolution: NavigationPathMismatchResolution<R>
    ) -> NavigationStoreTelemetryEvent<R>.PathMismatchResolution {
        switch resolution {
        case .single(let command):
            return .single(command)
        case .batch(let commands):
            return .batch(commands)
        case .ignore:
            return .ignore
        }
    }

    private static func pathSummary(for path: [R]) -> String {
        path.map(routeSummary(for:)).joined(separator: " -> ")
    }

    private static func routeSummary(for route: R) -> String {
        let description = String(describing: route)
        return description
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? description
    }
}
