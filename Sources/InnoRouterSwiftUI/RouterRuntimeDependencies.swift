import Foundation

import InnoRouterCore

/// Package-only sources of time and correlation identity used by the runtime.
///
/// Keeping these dependencies out of the public configuration preserves the
/// macro-first facade while allowing deterministic package and sanitizer tests
/// to advance suspended work without wall-clock sleeps.
package struct RouterRuntimeDependencies: Sendable {
    package var now: @Sendable () -> Date
    package var sleep: @Sendable (Duration) async throws -> Void
    package var makeTransitionID: @Sendable () -> RouterTransitionID
    package var didQueueRequest: @MainActor @Sendable (RouterTransitionID) -> Void

    package init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        makeTransitionID: @escaping @Sendable () -> RouterTransitionID,
        didQueueRequest: @escaping @MainActor @Sendable (RouterTransitionID) -> Void = { _ in }
    ) {
        self.now = now
        self.sleep = sleep
        self.makeTransitionID = makeTransitionID
        self.didQueueRequest = didQueueRequest
    }

    package static let live = Self(
        now: Date.init,
        sleep: { duration in
            try await Task.sleep(for: duration)
        },
        makeTransitionID: RouterTransitionID.init,
        didQueueRequest: { _ in }
    )
}
