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
    /// The URL did not match any ``FlowDeepLinkMapping``.
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
/// 1. Validate the URL's scheme / host.
/// 2. Walk the matcher for a `FlowPlan`.
/// 3. Run the authentication policy against every route in the plan.
/// 4. Return `.flowPlan(plan)` or `.pending(...)` as appropriate.
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
    public let allowedSchemes: Set<String>?
    public let allowedHosts: Set<String>?
    public let matcher: FlowDeepLinkMatcher<R>
    public let authenticationPolicy: DeepLinkAuthenticationPolicy<R>
    public let inputLimits: DeepLinkInputLimits

    public init(
        allowedSchemes: Set<String>? = nil,
        allowedHosts: Set<String>? = nil,
        matcher: FlowDeepLinkMatcher<R>,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default
    ) {
        self.allowedSchemes = allowedSchemes?.flowLowercasedSet
        self.allowedHosts = allowedHosts?.flowLowercasedSet
        self.matcher = matcher
        self.authenticationPolicy = authenticationPolicy
        self.inputLimits = inputLimits
    }

    public func decide(for url: URL) -> FlowDeepLinkDecision<R> {
        // Preserve the raw-length resource guard before doing any URL
        // parsing. Every later limit check and pattern walk reuses the
        // same parsed value.
        if let violation = inputLimits.urlLengthViolation(for: url) {
            return .rejected(reason: .inputLimitExceeded(violation))
        }

        let parsed = DeepLinkParser.parse(url)

        if let violation = inputLimits.parsedContentViolation(for: parsed) {
            return .rejected(reason: .inputLimitExceeded(violation))
        }

        if let allowedSchemes {
            guard let scheme = url.scheme?.lowercased() else {
                return .rejected(reason: .schemeNotAllowed(actualScheme: url.scheme))
            }
            guard allowedSchemes.contains(scheme) else {
                return .rejected(reason: .schemeNotAllowed(actualScheme: url.scheme))
            }
        }

        if let allowedHosts {
            guard let host = url.host?.lowercased() else {
                return .rejected(reason: .hostNotAllowed(actualHost: url.host))
            }
            guard allowedHosts.contains(host) else {
                return .rejected(reason: .hostNotAllowed(actualHost: url.host))
            }
        }

        if let violation = matcher.inputLimitViolation(for: url, parsed: parsed) {
            return .rejected(reason: .inputLimitExceeded(violation))
        }

        guard let plan = matcher.match(parsed: parsed) else {
            return .unhandled(url: url)
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
}

private extension Set where Element == String {
    var flowLowercasedSet: Set<String> {
        Set(map { $0.lowercased() })
    }
}
