// MARK: - FlowDeepLinkPipeline.swift
// InnoRouterDeepLink - composite URL → FlowPlan<R> pipeline with auth policy
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import InnoRouterCore

/// Authentication-deferred composite deep link, queued for replay once
/// the gate permits it.
///
/// Mirrors ``PendingDeepLink`` but carries a ``FlowPlan`` instead of a
/// push-only ``NavigationPlan``. `gatedRoute` records the first route
/// inside the plan that triggered the authentication deferral, so
/// replay can re-check the same protected destination instead of
/// assuming the plan's first step is always the gated one.
public struct FlowPendingDeepLink<R: Route>: Sendable, Equatable {
    public let url: URL
    public let gatedRoute: R
    public let plan: FlowPlan<R>

    public init(url: URL, gatedRoute: R, plan: FlowPlan<R>) {
        self.url = url
        self.gatedRoute = gatedRoute
        self.plan = plan
    }
}

// MARK: - Codable (opt-in when the underlying route is Codable)

extension FlowPendingDeepLink: Encodable where R: Encodable {}
extension FlowPendingDeepLink: Decodable where R: Decodable {}

/// Outcome of ``FlowDeepLinkPipeline/decide(for:)``.
///
/// Parallels ``DeepLinkDecision``. Kept as a separate enum so adding
/// `.flowPlan` is not a breaking change to consumers of the push-only
/// surface — both pipelines coexist and callers pick whichever output
/// type matches their store.
public enum FlowDeepLinkDecision<R: Route>: Sendable, Equatable {
    /// The URL was rejected by scheme or host validation.
    case rejected(reason: DeepLinkRejectionReason)
    /// The URL did not match any `DeepLinkMapping<FlowPlan<R>>`.
    case unhandled(url: URL)
    /// Authentication gate deferred the URL; caller should queue it
    /// and replay once authenticated.
    case pending(FlowPendingDeepLink<R>)
    /// The URL matched and produced a plan.
    case flowPlan(FlowPlan<R>)
}

/// Deep-link pipeline that emits composite ``FlowPlan`` values, so a
/// single URL can describe a push prefix plus a modal terminal step
/// that `FlowStore.apply(_:)` replays atomically.
///
/// Composition mirrors ``DeepLinkPipeline``:
///
/// 1. Enforce pipeline input limits.
/// 2. Validate the URL's scheme / host.
/// 3. Enforce matcher input limits and walk it for a `FlowPlan`.
/// 4. Run the authentication policy against every route in the plan.
/// 5. Return `.flowPlan(plan)` or `.pending(...)` as appropriate.
///
/// ## Multi-step authentication semantics
///
/// When `authenticationPolicy == .required(...)` and the matched plan
/// contains *multiple* steps, the pipeline scans the plan in plan-step
/// order and returns the **first** route flagged as protected by
/// `shouldRequireAuthentication` as the
/// ``FlowPendingDeepLink/gatedRoute``.
///
/// `.pending` is **all-or-nothing**: when any step in a plan is gated,
/// the pipeline does not commit the unprotected prefix. The full plan
/// is queued in ``FlowPendingDeepLink/plan`` and replayed atomically
/// once authentication succeeds. This means that a plan such as
/// `[push(.home), push(.profile)]` with only `.profile` gated will:
///
/// - return `.pending(gatedRoute: .profile, plan: <full plan>)`,
/// - leave the navigation/modal stacks untouched (no `.home` push),
/// - re-validate the same protected route on replay (`.profile`),
///   so a stale gate that resolves between defer and replay still
///   blocks the appropriate step.
///
/// Callers that want partial application (commit unprotected prefix
/// immediately, defer only the gated suffix) must split the plan
/// upstream — the pipeline intentionally does not infer where it is
/// safe to break a multi-step plan, because user-visible side effects
/// often depend on the plan's atomicity (analytics, telemetry, screen
/// transitions).
public struct FlowDeepLinkPipeline<R: Route>: Sendable {
    private let admission: DeepLinkAdmission<FlowPlan<R>>
    private let authenticationPolicy: DeepLinkAuthenticationPolicy<R>

    public init(
        allowedSchemes: Set<String>? = nil,
        allowedHosts: Set<String>? = nil,
        matcher: DeepLinkMatcher<FlowPlan<R>>,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default
    ) {
        self.admission = DeepLinkAdmission(
            allowedSchemes: allowedSchemes,
            allowedHosts: allowedHosts,
            matcher: matcher,
            inputLimits: inputLimits
        )
        self.authenticationPolicy = authenticationPolicy
    }

    public func decide(for url: URL) -> FlowDeepLinkDecision<R> {
        let plan: FlowPlan<R>
        switch admission.evaluate(url) {
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .unhandled:
            return .unhandled(url: url)
        case .matched(let matchedPlan):
            plan = matchedPlan
        }

        switch authenticationPolicy {
        case .notRequired:
            return .flowPlan(plan)

        case .required(let shouldRequireAuthentication, let isAuthenticated):
            for route in plan.steps.map(\.route) {
                if shouldRequireAuthentication(route), !isAuthenticated() {
                    return .pending(
                        FlowPendingDeepLink(url: url, gatedRoute: route, plan: plan)
                    )
                }
            }
            return .flowPlan(plan)
        }
    }

    package func canResume(_ route: R) -> Bool {
        switch authenticationPolicy {
        case .notRequired:
            return true
        case .required(let shouldRequireAuthentication, let isAuthenticated):
            return !shouldRequireAuthentication(route) || isAuthenticated()
        }
    }
}
