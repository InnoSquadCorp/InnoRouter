// MARK: - RouterLinkPipeline.swift
// InnoRouterDeepLink - canonical URL to whole-router plan pipeline
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// App-owned authentication admission used by the canonical link pipeline.
public enum DeepLinkAuthenticationPolicy<R: Route>: Sendable {
    case notRequired
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

    public var localizedDescription: String {
        switch self {
        case .schemeNotAllowed(let actualScheme):
            return "Deep-link scheme is not allowed: \(actualScheme ?? "nil")."
        case .hostNotAllowed(let actualHost):
            return "Deep-link origin is not allowed: \(actualHost ?? "nil")."
        case .inputLimitExceeded(let violation):
            return violation.localizedDescription
        }
    }
}

/// An authenticated deep link retained until the application can apply its
/// complete target state.
public struct PendingRouterLink<R: Route>: Sendable, Equatable {
    public let url: URL
    public let gatedRoute: R
    public let plan: RouterPlan<R>

    public init(url: URL, gatedRoute: R, plan: RouterPlan<R>) {
        self.url = url
        self.gatedRoute = gatedRoute
        self.plan = plan
    }
}

extension PendingRouterLink: Codable where R: Codable {}

/// One terminal admission decision for a canonical router deep link.
public enum RouterLinkDecision<R: Route>: Sendable, Equatable {
    case rejected(reason: DeepLinkRejectionReason)
    case unhandled(url: URL)
    case pending(PendingRouterLink<R>)
    case plan(RouterPlan<R>)
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
        case .pending:
            preconditionFailure("Admission never produces a pending link")
        case .plan(let plan):
            return await authenticatedDecision(for: url, plan: plan)
        }
    }

    /// Performs only the synchronous origin and matcher admission phase.
    ///
    /// Package clients use this to arbitrate nested macro-first hosts before
    /// the winning host awaits application-owned authentication state.
    package func admittedDecision(for url: URL) -> RouterLinkDecision<R> {
        let plan: RouterPlan<R>
        switch source {
        case .plans(let admission):
            switch admission.evaluate(url) {
            case .rejected(let reason): return .rejected(reason: reason)
            case .unhandled: return .unhandled(url: url)
            case .matched(let matchedPlan): plan = matchedPlan
            }
        case .routes(let admission, let planner):
            switch admission.evaluate(url) {
            case .rejected(let reason): return .rejected(reason: reason)
            case .unhandled: return .unhandled(url: url)
            case .matched(let route): plan = planner(route)
            }
        }

        return .plan(plan)
    }

    package func authenticatedDecision(
        for url: URL,
        plan: RouterPlan<R>
    ) async -> RouterLinkDecision<R> {
        switch authenticationPolicy {
        case .notRequired:
            return .plan(plan)
        case .required(let shouldRequireAuthentication, let isAuthenticated):
            if let gated = plan.authenticationRoutes.first(where: shouldRequireAuthentication),
               !(await isAuthenticated()) {
                return .pending(
                    PendingRouterLink(url: url, gatedRoute: gated, plan: plan)
                )
            }
            return .plan(plan)
        }
    }
}

private extension RouterPlan {
    var authenticationRoutes: [R] {
        var routes: [R] = []
        func visit(_ node: RouterNode<R>) {
            switch node {
            case .stack(let stack):
                routes.append(contentsOf: stack.path)
                if let presentation = stack.presentation {
                    routes.append(presentation.route)
                }
            case .container(let container):
                for branch in container.branches {
                    visit(branch.node)
                }
            }
        }
        visit(state.root)
        for window in state.windows {
            routes.append(window.route)
            visit(window.node)
        }
        if let immersiveSpace = state.immersiveSpace {
            routes.append(immersiveSpace.route)
            visit(immersiveSpace.node)
        }
        return routes
    }
}
