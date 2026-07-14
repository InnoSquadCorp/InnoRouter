import Foundation

import InnoRouterDeepLink
import InnoRouterSwiftUI

@MainActor
public protocol DeepLinkCoordinating: Coordinator {
    var deepLinkPipeline: DeepLinkPipeline<RouteType> { get }
    var pendingDeepLink: PendingDeepLink<RouteType>? { get set }
}

public extension DeepLinkCoordinating {
    /// Feeds `url` through the coordinator's pipeline and returns a typed
    /// outcome describing what happened.
    ///
    /// - `executed` is returned when the pipeline produces a plan that was
    ///   applied to `store` via `executeBatch`. The per-command batch result
    ///   is surfaced so callers can feed analytics/logging without peeking at
    ///   stack state.
    /// - `pending` is returned when the pipeline defers execution pending
    ///   authentication; the value is also stored on `pendingDeepLink`.
    /// - `rejected` / `unhandled` surface pipeline refusals that were
    ///   previously invisible to Umbrella callers (the old `Void` return hid
    ///   these cases and callers had no way to route them to error UX).
    @discardableResult
    func handleDeepLink(_ url: URL) -> DeepLinkCoordinationOutcome<RouteType> {
        switch deepLinkPipeline.decide(for: url) {
        case .rejected(let reason):
            return .rejected(reason: reason)

        case .unhandled(let unhandledURL):
            return .unhandled(url: unhandledURL)

        case .pending(let pending):
            pendingDeepLink = pending
            return .pending(pending)

        case .plan(let plan):
            pendingDeepLink = nil
            if let failure = plan.validationFailure(on: store.state) {
                return .applicationRejected(plan: plan, failure: failure)
            }
            let batch = store.executeBatch(plan.commands)
            return .executed(plan: plan, batch: batch)
        }
    }

    /// Re-attempts the stored `pendingDeepLink` when authentication allows.
    ///
    /// - `noPendingDeepLink`: no pending deep link to replay.
    /// - `pending`: authentication is still required; the pending deep link
    ///   remains stored.
    /// - `executed`: the stored plan was applied.
    @discardableResult
    func resumePendingDeepLinkIfPossible() -> DeepLinkCoordinationOutcome<RouteType> {
        guard let pendingDeepLink else { return .noPendingDeepLink }
        if !deepLinkPipeline.canResume(pendingDeepLink.route) {
            return .pending(pendingDeepLink)
        }

        // Safe to clear first: we iterate on the local `pendingDeepLink` constant, not the stored property.
        self.pendingDeepLink = nil
        if let failure = pendingDeepLink.plan.validationFailure(on: store.state) {
            return .applicationRejected(plan: pendingDeepLink.plan, failure: failure)
        }
        let batch = store.executeBatch(pendingDeepLink.plan.commands)
        return .executed(plan: pendingDeepLink.plan, batch: batch)
    }

    /// Async guard that authorizes the captured pending deep link before
    /// resuming. Mirrors `DeepLinkEffectHandler.resumePendingDeepLinkIfAllowed`
    /// semantics:
    ///
    /// - If the pending deep link changed during `authorize` (stale identity),
    ///   returns `.pending(currentPending)` or `.noPendingDeepLink` without
    ///   running the captured plan.
    /// - If the authorizer denies, returns `.pending(captured)`.
    /// - Otherwise delegates to `resumePendingDeepLinkIfPossible()`.
    @discardableResult
    func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (PendingDeepLink<RouteType>) async -> Bool
    ) async -> DeepLinkCoordinationOutcome<RouteType> {
        guard let pendingDeepLink else { return .noPendingDeepLink }
        let capturedPendingDeepLink = pendingDeepLink
        let isAuthorized = await authorize(capturedPendingDeepLink)

        guard self.pendingDeepLink == capturedPendingDeepLink else {
            if let currentPendingDeepLink = self.pendingDeepLink {
                return .pending(currentPendingDeepLink)
            }
            return .noPendingDeepLink
        }

        guard isAuthorized else {
            return .pending(capturedPendingDeepLink)
        }

        return resumePendingDeepLinkIfPossible()
    }

    /// Throwing async guard for authorization probes that can fail before a
    /// boolean decision is available.
    @discardableResult
    func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (PendingDeepLink<RouteType>) async throws -> Bool
    ) async rethrows -> DeepLinkCoordinationOutcome<RouteType> {
        guard let pendingDeepLink else { return .noPendingDeepLink }
        let capturedPendingDeepLink = pendingDeepLink
        let isAuthorized = try await authorize(capturedPendingDeepLink)

        guard self.pendingDeepLink == capturedPendingDeepLink else {
            if let currentPendingDeepLink = self.pendingDeepLink {
                return .pending(currentPendingDeepLink)
            }
            return .noPendingDeepLink
        }

        guard isAuthorized else {
            return .pending(capturedPendingDeepLink)
        }

        return resumePendingDeepLinkIfPossible()
    }
}
