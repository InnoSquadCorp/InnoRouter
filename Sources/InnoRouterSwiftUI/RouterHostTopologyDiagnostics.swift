import OSLog

/// Reports a supplied store whose root is not the container a host renders.
///
/// Host initializers are SwiftUI `View` initializers, re-run on every parent
/// body pass, and exact restoration can replace a store's root with any valid
/// decoded shape. A host therefore renders without that state instead of
/// trapping, and this warning is the signal that remains. It is logged once
/// per host type so a mismatch that persists across body passes cannot flood
/// the log.
@MainActor
enum RouterHostTopologyDiagnostics {
    private static let logger = Logger(
        subsystem: "io.innosquad.innorouter",
        category: "host-topology"
    )
    private static var reportedHosts: Set<String> = []

    static func reportMismatch(host: String, expected: String) {
        guard reportedHosts.insert(host).inserted else { return }
        logger.warning(
            """
            \(host, privacy: .public) was given a store whose root is not \
            \(expected, privacy: .public). It renders without that state and \
            rejects navigation into it. Bump RouterSnapshotCodec.currentVersion \
            to reject or migrate a snapshot written for a different root.
            """
        )
    }
}
