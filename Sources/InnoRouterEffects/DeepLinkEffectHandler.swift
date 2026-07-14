// MARK: - DeepLinkEffectHandler.swift
// InnoRouterEffects - DeepLink Effect Handler
// Copyright © 2025 Inno Squad. All rights reserved.

import Foundation
import InnoRouterCore
import InnoRouterDeepLink

/// App-boundary helper that runs a `DeepLinkPipeline` against an
/// incoming URL and dispatches the resulting `NavigationPlan` through
/// a `NavigationEffectHandler`, while caching `pending(...)` outcomes
/// so a deferred deep link can be replayed after authentication.
@MainActor
public final class DeepLinkEffectHandler<R: Route> {
    public enum Result: Sendable, Equatable {
        /// Every command in the matched plan completed successfully.
        case executed(plan: NavigationPlan<R>, batch: NavigationBatchResult<R>)
        /// Execution was attempted, but at least one command failed or was
        /// cancelled. The batch may contain partial state changes.
        case executionFailed(plan: NavigationPlan<R>, batch: NavigationBatchResult<R>)
        /// Preflight rejected the plan before execution, so navigation state
        /// was not changed by this handler call.
        case applicationRejected(plan: NavigationPlan<R>, failure: NavigationPlanValidationFailure<R>)
        /// Authentication deferred the URL and the handler retained its plan
        /// for a later replay.
        case pending(PendingDeepLink<R>)
        /// The pipeline rejected the URL through its admission policy.
        case rejected(reason: DeepLinkRejectionReason)
        /// The pipeline admitted the URL but no mapping resolved it.
        case unhandled(url: URL)
        /// String input could not be parsed as a URL.
        case invalidURL(input: String)
        /// The supplied effect carried no URL.
        case missingDeepLinkURL
        /// Replay was requested while the pending slot was empty.
        case noPendingDeepLink
    }

    private let pipeline: DeepLinkPipeline<R>
    private let navigationHandler: NavigationEffectHandler<R>
    private var pendingReplaySlot = PendingReplaySlot<PendingDeepLink<R>>()

    /// The request currently retained for authentication-gated replay.
    public var pendingDeepLink: PendingDeepLink<R>? {
        pendingReplaySlot.current
    }

    /// Creates a handler around an already configured pipeline. Coordinator
    /// and app-shell owners can keep planning configuration in one pipeline
    /// and delegate execution and pending replay to this handler.
    public init<N: Navigator & NavigationBatchExecutor & NavigationTransactionExecutor>(
        pipeline: DeepLinkPipeline<R>,
        navigator: N
    ) where N.RouteType == R {
        self.pipeline = pipeline
        self.navigationHandler = NavigationEffectHandler(navigator: navigator)
    }

    public init<N: Navigator & NavigationBatchExecutor & NavigationTransactionExecutor>(
        navigator: N,
        matcher: DeepLinkMatcher<R>,
        allowedSchemes: Set<String>? = nil,
        allowedHosts: Set<String>? = nil,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping DeepLinkPipeline<R>.Planner = { route in
            NavigationPlan(commands: [.push(route)])
        }
    ) where N.RouteType == R {
        self.pipeline = DeepLinkPipeline(
            allowedSchemes: allowedSchemes,
            allowedHosts: allowedHosts,
            matcher: matcher,
            authenticationPolicy: authenticationPolicy,
            inputLimits: inputLimits,
            plan: plan
        )
        self.navigationHandler = NavigationEffectHandler(navigator: navigator)
    }

    public func handle(_ url: URL) -> Result {
        switch pipeline.decide(for: url) {
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .unhandled(let unhandledURL):
            return .unhandled(url: unhandledURL)
        case .pending(let pendingDeepLink):
            pendingReplaySlot.replace(with: pendingDeepLink)
            return .pending(pendingDeepLink)
        case .plan(let plan):
            pendingReplaySlot.replace(with: nil)
            return result(for: plan)
        }
    }

    public func handle(_ urlString: String) -> Result {
        guard let url = URL(string: urlString) else {
            return .invalidURL(input: urlString)
        }
        return handle(url)
    }

    public func resumePendingDeepLink() -> Result {
        guard let ticket = pendingReplaySlot.capture() else {
            return .noPendingDeepLink
        }
        return result(for: ticket, externallyAuthorized: true)
    }

    /// Awaits a live authorization probe before re-evaluating the pipeline's
    /// gate. A pending request replaced while the probe is suspended remains
    /// pending, even when the replacement has the same URL and plan.
    public func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (PendingDeepLink<R>) async throws -> Bool
    ) async rethrows -> Result {
        guard let ticket = pendingReplaySlot.capture() else {
            return .noPendingDeepLink
        }
        let isAuthorized = try await authorize(ticket.value)
        return result(for: ticket, externallyAuthorized: isAuthorized)
    }

    /// Drops the retained request without executing its plan.
    public func clearPendingDeepLink() {
        pendingReplaySlot.replace(with: nil)
    }

    /// Reinstalls a pending request handed off by application-owned state. The
    /// restored request supersedes any in-flight authorization for the
    /// previous slot, even when both values compare equal.
    public func restore(pending: PendingDeepLink<R>) {
        pendingReplaySlot.replace(with: pending)
    }

    private func result(
        for ticket: PendingReplaySlot<PendingDeepLink<R>>.Ticket,
        externallyAuthorized: Bool
    ) -> Result {
        guard pendingReplaySlot.isCurrent(ticket) else {
            return result(for: pendingReplaySlot.resolve(ticket, allowReplay: false))
        }

        let allowReplay = externallyAuthorized && canResume(ticket.value)
        return result(for: pendingReplaySlot.resolve(ticket, allowReplay: allowReplay))
    }

    private func result(
        for resolution: PendingReplaySlot<PendingDeepLink<R>>.Resolution
    ) -> Result {
        switch resolution {
        case .noPending:
            return .noPendingDeepLink
        case .pending(let pending):
            return .pending(pending)
        case .replay(let pending):
            return result(for: pending.plan)
        }
    }

    private func result(for plan: NavigationPlan<R>) -> Result {
        if let failure = plan.validationFailure(on: navigationHandler.state) {
            return .applicationRejected(plan: plan, failure: failure)
        }
        let batch = navigationHandler.execute(plan.commands)
        return batch.isSuccess
            ? .executed(plan: plan, batch: batch)
            : .executionFailed(plan: plan, batch: batch)
    }

    private func canResume(_ pendingDeepLink: PendingDeepLink<R>) -> Bool {
        pipeline.canResume(pendingDeepLink.route)
    }
}

public protocol DeepLinkEffect {
    var deepLinkURL: URL? { get }
    static func deepLink(_ url: URL) -> Self
}

public extension DeepLinkEffectHandler {
    func handle<E: DeepLinkEffect>(_ effect: E) -> Result {
        guard let url = effect.deepLinkURL else {
            return .missingDeepLinkURL
        }
        return handle(url)
    }
}
