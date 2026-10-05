// MARK: - RouterLinkPipeline.swift
// InnoRouterDeepLink - canonical URL to whole-router plan pipeline
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// App-owned authentication admission used by the canonical link pipeline.
public enum DeepLinkAuthenticationPolicy<R: Route>: Sendable {
    case notRequired
    /// Generation-aware authorization with selected-root declaration metadata.
    case configured(RouterAuthorizationConfiguration<R>)
    case required(
        shouldRequireAuthentication: @Sendable (R) -> Bool,
        isAuthenticated: @Sendable () async -> Bool
    )
}

/// A fail-closed URL admission failure.
public enum DeepLinkRejectionReason: Sendable, Equatable {
    case schemeNotAllowed(actualScheme: String?)
    case hostNotAllowed(actualHost: String?)
    case inputLimitExceeded(DeepLinkInputLimitViolation)
    case authorization(RouterAuthorizationFailure)

    public var localizedDescription: String {
        switch self {
        case .schemeNotAllowed(let actualScheme):
            return "Deep-link scheme is not allowed: \(actualScheme ?? "nil")."
        case .hostNotAllowed(let actualHost):
            return "Deep-link origin is not allowed: \(actualHost ?? "nil")."
        case .inputLimitExceeded(let violation):
            return violation.localizedDescription
        case .authorization(let failure):
            return "Deep-link authorization rejected: \(failure.code.rawValue)."
        }
    }
}

/// An authenticated deep link retained until the application can apply its
/// complete target state.
public struct PendingRouterLink<R: Route>: Sendable, Equatable {
    public let url: URL
    public let gatedRoute: R
    public let plan: RouterPlan<R>
    /// Original matched intent, even when a planner removes it from the state.
    public let matchedRoute: R?
    /// Persisted links and authenticated admission require fresh URL admission.
    public let isRevalidationRequired: Bool

    public init(url: URL, gatedRoute: R, plan: RouterPlan<R>, matchedRoute: R? = nil, isRevalidationRequired: Bool = false) {
        self.url = url
        self.gatedRoute = gatedRoute
        self.plan = plan
        self.matchedRoute = matchedRoute
        self.isRevalidationRequired = isRevalidationRequired
    }
}

extension PendingRouterLink: Codable where R: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, gatedRoute, plan, matchedRoute
        case isRevalidationRequired = "requiresRevalidation"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        gatedRoute = try container.decode(R.self, forKey: .gatedRoute)
        plan = try container.decode(RouterPlan<R>.self, forKey: .plan)
        matchedRoute = try container.decodeIfPresent(R.self, forKey: .matchedRoute)
        // Stored input is intent, never proof of prior admission or authority.
        isRevalidationRequired = true
    }
}

/// One terminal admission decision for a canonical router deep link.
public enum RouterLinkDecision<R: Route>: Sendable, Equatable {
    case rejected(reason: DeepLinkRejectionReason)
    case unhandled(url: URL)
    case pending(PendingRouterLink<R>)
    case plan(RouterPlan<R>)
}

/// One synchronous admission retains intent independently of materialized state.
/// A selected tab root need not appear in a stack path, so the original route
/// must survive host arbitration without parsing the URL a second time.
package struct RouterAdmittedLink<R: Route>: Sendable {
    package let plan: RouterPlan<R>
    package let matchedRoute: R?

    package init(plan: RouterPlan<R>, matchedRoute: R? = nil) {
        self.plan = plan
        self.matchedRoute = matchedRoute
    }
}

package enum RouterLinkAdmission<R: Route>: Sendable {
    case rejected(DeepLinkRejectionReason)
    case unhandled
    case matched(RouterAdmittedLink<R>)
}

/// Maps an admitted URL directly to the same complete ``RouterPlan`` used by
/// restoration and transactions.
///
/// This replaces separate push-only and flow-only planning concepts in the
/// InnoRouter 6 surface. A plan can target a stack, selected tab/split branch,
/// modal, regular window, and immersive space in one validated value.
public struct RouterLinkPipeline<R: Route>: Sendable {
    public typealias Planner = @Sendable (R) -> RouterPlan<R>

    private enum Source: Sendable {
        case plans(DeepLinkAdmission<RouterPlan<R>>)
        case routes(DeepLinkAdmission<R>, Planner)
    }

    private let source: Source
    private let authenticationPolicy: DeepLinkAuthenticationPolicy<R>

    /// Creates a pipeline whose matcher already returns complete plans.
    public init(
        originPolicy: DeepLinkOriginPolicy,
        matcher: DeepLinkMatcher<RouterPlan<R>>,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default
    ) {
        self.source = .plans(
            DeepLinkAdmission(
                originPolicy: originPolicy,
                matcher: matcher,
                inputLimits: inputLimits
            )
        )
        self.authenticationPolicy = authenticationPolicy
    }

    /// Creates a macro-friendly single-route pipeline and promotes every match
    /// into a complete router plan. The default replaces the root stack with
    /// exactly the resolved route.
    public init(
        originPolicy: DeepLinkOriginPolicy,
        matcher: DeepLinkMatcher<R>,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping Planner = { route in
            RouterPlan(state: .rootStack(path: [route]))
        }
    ) {
        self.source = .routes(
            DeepLinkAdmission(
                originPolicy: originPolicy,
                matcher: matcher,
                inputLimits: inputLimits
            ),
            plan
        )
        self.authenticationPolicy = authenticationPolicy
    }

    /// Creates a fail-closed custom-resolver pipeline.
    public init(
        originPolicy: DeepLinkOriginPolicy,
        customResolver: @escaping @Sendable (URL) -> RouterPlan<R>?,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default
    ) {
        self.source = .plans(
            DeepLinkAdmission(
                originPolicy: originPolicy,
                customResolver: customResolver,
                inputLimits: inputLimits
            )
        )
        self.authenticationPolicy = authenticationPolicy
    }

    /// Resolves and authenticates one URL without constraining application
    /// session state to a specific actor.
    public func decide(for url: URL) async -> RouterLinkDecision<R> {
        switch admittedDecision(for: url) {
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .unhandled:
            return .unhandled(url: url)
        case .matched(let request):
            return await authenticatedDecision(for: url, request: request)
        }
    }

    /// Performs only the synchronous origin and matcher admission phase.
    ///
    /// Package clients use this to arbitrate nested macro-first hosts before
    /// the winning host awaits application-owned authentication state.
    package func admittedDecision(for url: URL) -> RouterLinkAdmission<R> {
        let request: RouterAdmittedLink<R>
        switch source {
        case .plans(let admission):
            switch admission.evaluate(url) {
            case .rejected(let reason): return .rejected(reason)
            case .unhandled: return .unhandled
            case .matched(let matchedPlan): request = RouterAdmittedLink(plan: matchedPlan)
            }
        case .routes(let admission, let planner):
            switch admission.evaluate(url) {
            case .rejected(let reason): return .rejected(reason)
            case .unhandled: return .unhandled
            case .matched(let route): request = RouterAdmittedLink(plan: planner(route), matchedRoute: route)
            }
        }

        return .matched(request)
    }

    package var authorizationConfiguration: RouterAuthorizationConfiguration<R>? {
        switch authenticationPolicy {
        case .notRequired: nil
        case .configured(let configuration): configuration
        case .required(let requiresAuthorization, let isAuthenticated):
            .init(requiresAuthorization: requiresAuthorization, authorize: { await isAuthenticated() })
        }
    }

    /// Standalone resolution is preflight only. Applying the returned plan to a
    /// Store still requires that Store's authoritative authorization contract.
    @MainActor
    package func authenticatedDecision(
        for url: URL,
        request: RouterAdmittedLink<R>
    ) async -> RouterLinkDecision<R> {
        guard let configuration = authorizationConfiguration else { return .plan(request.plan) }
        let generation = configuration.generation?()
        let targets: [R]
        do {
            targets = try configuration.targets(in: request.plan.state, matchedRoutes: request.matchedRoute.map { [$0] } ?? [])
        } catch let failure as RouterAuthorizationFailure {
            return .rejected(reason: .authorization(failure))
        } catch {
            preconditionFailure("Authorization target resolution produced an undocumented error")
        }
        guard let gated = targets.first(where: configuration.requiresAuthorization) else { return .plan(request.plan) }
        let authorized = await configuration.authorize()
        guard generation == configuration.generation?() else {
            return .rejected(reason: .authorization(.init(code: .generationChanged)))
        }
        guard authorized else {
            return .pending(PendingRouterLink(
                url: url, gatedRoute: gated, plan: request.plan,
                matchedRoute: request.matchedRoute, isRevalidationRequired: true
            ))
        }
        return .plan(request.plan)
    }
}
