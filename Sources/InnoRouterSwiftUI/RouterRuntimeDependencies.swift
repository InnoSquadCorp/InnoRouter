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
    package var beforeRestorationWorker: @MainActor @Sendable () async throws -> Void
    package var didFinishRestorationWorker: @MainActor @Sendable () -> Void
    package var didFinishImmersiveDisappearance: @MainActor @Sendable () -> Void
    package var willEnqueueRestorationSave: @MainActor @Sendable () -> Void = {}
    package var didFinishRestorationSave: @MainActor @Sendable () -> Void = {}
    package var didFinishSceneLifecycleSave: @MainActor @Sendable () -> Void = {}

    package init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        makeTransitionID: @escaping @Sendable () -> RouterTransitionID,
        didQueueRequest: @escaping @MainActor @Sendable (RouterTransitionID) -> Void = { _ in },
        beforeRestorationWorker: @escaping @MainActor @Sendable () async throws -> Void = {},
        didFinishRestorationWorker: @escaping @MainActor @Sendable () -> Void = {},
        didFinishImmersiveDisappearance: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.now = now
        self.sleep = sleep
        self.makeTransitionID = makeTransitionID
        self.didQueueRequest = didQueueRequest
        self.beforeRestorationWorker = beforeRestorationWorker
        self.didFinishRestorationWorker = didFinishRestorationWorker
        self.didFinishImmersiveDisappearance = didFinishImmersiveDisappearance
    }

    package static let live = Self(
        now: Date.init,
        sleep: { duration in
            try await Task.sleep(for: duration)
        },
        makeTransitionID: RouterTransitionID.init,
        didQueueRequest: { _ in },
        beforeRestorationWorker: {}
    )
}
