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
        case executed(plan: NavigationPlan<R>, batch: NavigationBatchResult<R>)
        case applicationRejected(plan: NavigationPlan<R>, failure: NavigationPlanValidationFailure<R>)
        case pending(PendingDeepLink<R>)
        case rejected(reason: DeepLinkRejectionReason)
        case unhandled(url: URL)
        case invalidURL(input: String)
        case missingDeepLinkURL
        case noPendingDeepLink
    }

    private let pipeline: DeepLinkPipeline<R>
    private let navigationHandler: NavigationEffectHandler<R>

    public private(set) var pendingDeepLink: PendingDeepLink<R>?

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
            self.pendingDeepLink = pendingDeepLink
            return .pending(pendingDeepLink)
        case .plan(let plan):
            self.pendingDeepLink = nil
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
        guard let pendingDeepLink else {
            return .noPendingDeepLink
        }

        if !canResume(pendingDeepLink) {
            return .pending(pendingDeepLink)
        }

        self.pendingDeepLink = nil
        return result(for: pendingDeepLink.plan)
    }

    public func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (PendingDeepLink<R>) async throws -> Bool
    ) async rethrows -> Result {
        guard let pendingDeepLink else {
            return .noPendingDeepLink
        }
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

        return resumePendingDeepLink()
    }

    public func clearPendingDeepLink() {
        pendingDeepLink = nil
    }

    private func result(for plan: NavigationPlan<R>) -> Result {
        if let failure = plan.validationFailure(on: navigationHandler.state) {
            return .applicationRejected(plan: plan, failure: failure)
        }
        let batch = navigationHandler.execute(plan.commands)
        return .executed(plan: plan, batch: batch)
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
