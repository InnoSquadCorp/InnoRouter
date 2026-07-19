import Foundation

import InnoRouterCore

public struct PendingDeepLink<R: Route>: Sendable, Equatable {
    public let url: URL
    /// The route that triggered authentication deferral.
    ///
    /// For the default `.push(route)` planner this is the resolved
    /// route. For custom planners it can be a protected route found
    /// inside the produced `NavigationPlan`.
    public let route: R
    public let plan: NavigationPlan<R>

    public init(url: URL, route: R, plan: NavigationPlan<R>) {
        self.url = url
        self.route = route
        self.plan = plan
    }
}

public struct NavigationPlan<R: Route>: Sendable, Equatable {
    public var commands: [NavigationCommand<R>]

    public init(commands: [NavigationCommand<R>]) {
        self.commands = commands
    }

    public func validationFailure(on initialStack: RouteStack<R>) -> NavigationPlanValidationFailure<R>? {
        var preview = initialStack
        let engine = NavigationEngine<R>()
        for (index, command) in commands.enumerated() {
            let result = engine.apply(command, to: &preview)
            if !result.isSuccess {
                return NavigationPlanValidationFailure(
                    index: index,
                    command: command,
                    result: result
                )
            }
        }
        return nil
    }

    public func canExecute(on initialStack: RouteStack<R>) -> Bool {
        validationFailure(on: initialStack) == nil
    }
}

public struct NavigationPlanValidationFailure<R: Route>: Sendable, Equatable {
    public let index: Int
    public let command: NavigationCommand<R>
    public let result: NavigationResult<R>
}

public enum DeepLinkAuthenticationPolicy<R: Route>: Sendable {
    case notRequired
    case required(
        shouldRequireAuthentication: @Sendable (R) -> Bool,
        isAuthenticated: @Sendable () -> Bool
    )
}

public enum DeepLinkRejectionReason: Sendable, Equatable {
    case schemeNotAllowed(actualScheme: String?)
    case hostNotAllowed(actualHost: String?)
    case nonCanonicalOrigin
    case inputLimitExceeded(DeepLinkInputLimitViolation)

    public var localizedDescription: String {
        switch self {
        case .schemeNotAllowed(let actualScheme):
            return "Deep-link scheme is not allowed: \(actualScheme ?? "nil")."
        case .hostNotAllowed(let actualHost):
            return "Deep-link host is not allowed: \(actualHost ?? "nil")."
        case .nonCanonicalOrigin:
            return "Deep-link origin must not contain user information or an explicit port."
        case .inputLimitExceeded(let violation):
            return violation.localizedDescription
        }
    }
}

public enum DeepLinkDecision<R: Route>: Sendable, Equatable {
    case rejected(reason: DeepLinkRejectionReason)
    case unhandled(url: URL)
    case pending(PendingDeepLink<R>)
    case plan(NavigationPlan<R>)
}

public struct DeepLinkPipeline<R: Route>: Sendable {
    public typealias Planner = @Sendable (R) -> NavigationPlan<R>

    private let admission: DeepLinkAdmission<R>
    private let authenticationPolicy: DeepLinkAuthenticationPolicy<R>
    private let plan: Planner

    /// Creates a matcher-backed pipeline with an explicit URL-origin trust
    /// boundary. Use `.allowlisted` for every external URL entry point.
    public init(
        originPolicy: DeepLinkOriginPolicy,
        matcher: DeepLinkMatcher<R>,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping Planner = { route in NavigationPlan(commands: [.push(route)]) }
    ) {
        self.admission = DeepLinkAdmission(
            originPolicy: originPolicy,
            matcher: matcher,
            inputLimits: inputLimits
        )
        self.authenticationPolicy = authenticationPolicy
        self.plan = plan
    }

    /// Creates a resolver-backed pipeline with an explicit URL-origin trust
    /// boundary. A `nil` resolver result is treated as `.unhandled`.
    public init(
        originPolicy: DeepLinkOriginPolicy,
        customResolver: @escaping @Sendable (URL) -> R?,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping Planner = { route in NavigationPlan(commands: [.push(route)]) }
    ) {
        self.admission = DeepLinkAdmission(
            originPolicy: originPolicy,
            customResolver: customResolver,
            inputLimits: inputLimits
        )
        self.authenticationPolicy = authenticationPolicy
        self.plan = plan
    }

    /// Creates a matcher-backed pipeline that preserves matcher-specific input
    /// limit violations as typed rejections.
    ///
    /// - Important: This compatibility initializer allows
    ///   `allowedSchemes` and `allowedHosts` to default to `nil`,
    ///   and `nil` disables that admission check entirely. A pipeline that
    ///   receives attacker-controllable URLs (custom URL schemes, universal
    ///   links, QR/NFC payloads) should always pass both allowlists so the
    ///   decision stays fail-closed. The `@DeepLink` macro path enforces an
    ///   allowlist at compile time (`E020`); a hand-rolled pipeline is
    ///   expected to match that posture. Omit the allowlists only when every
    ///   incoming URL is constructed by your own process.
    public init(
        allowedSchemes: Set<String>? = nil,
        allowedHosts: Set<String>? = nil,
        matcher: DeepLinkMatcher<R>,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping Planner = { route in NavigationPlan(commands: [.push(route)]) }
    ) {
        self.admission = DeepLinkAdmission(
            allowedSchemes: allowedSchemes,
            allowedHosts: allowedHosts,
            matcher: matcher,
            inputLimits: inputLimits
        )
        self.authenticationPolicy = authenticationPolicy
        self.plan = plan
    }

    /// Creates a pipeline backed by an arbitrary URL resolver.
    ///
    /// A `nil` result is treated as `.unhandled`. Prefer the `matcher:`
    /// initializer when using `DeepLinkMatcher` so matcher-specific input-limit
    /// violations remain distinguishable from an unmatched URL.
    ///
    /// - Important: This compatibility initializer allows
    ///   `allowedSchemes` and `allowedHosts` to default to `nil`,
    ///   and `nil` disables that admission check entirely. Pass both
    ///   allowlists whenever the resolver can see attacker-controllable
    ///   URLs; see the `matcher:` initializer for the full rationale.
    public init(
        allowedSchemes: Set<String>? = nil,
        allowedHosts: Set<String>? = nil,
        customResolver: @escaping @Sendable (URL) -> R?,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping Planner = { route in NavigationPlan(commands: [.push(route)]) }
    ) {
        self.admission = DeepLinkAdmission(
            allowedSchemes: allowedSchemes,
            allowedHosts: allowedHosts,
            customResolver: customResolver,
            inputLimits: inputLimits
        )
        self.authenticationPolicy = authenticationPolicy
        self.plan = plan
    }

    public func decide(for url: URL) -> DeepLinkDecision<R> {
        let route: R
        switch admission.evaluate(url) {
        case .rejected(let reason):
            return .rejected(reason: reason)
        case .unhandled:
            return .unhandled(url: url)
        case .matched(let matchedRoute):
            route = matchedRoute
        }

        let navigationPlan = plan(route)
        switch authenticationPolicy {
        case .notRequired:
            break

        case .required(let shouldRequireAuthentication, let isAuthenticated):
            let candidateRoutes = navigationPlan.authenticationCandidateRoutes(
                fallback: route
            )
            if let gatedRoute = candidateRoutes.first(where: shouldRequireAuthentication),
               !isAuthenticated() {
                return .pending(PendingDeepLink(url: url, route: gatedRoute, plan: navigationPlan))
            }
        }

        return .plan(navigationPlan)
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

private extension NavigationPlan {
    func authenticationCandidateRoutes(fallback route: R) -> [R] {
        let plannedRoutes = commands.flatMap(\.authenticationCandidateRoutes)
        return plannedRoutes.isEmpty ? [route] : plannedRoutes
    }
}

private extension NavigationCommand {
    var authenticationCandidateRoutes: [R] {
        switch self {
        case .push(let route):
            return [route]
        case .pushAll(let routes), .replace(let routes):
            return routes
        case .popTo(let route):
            return [route]
        case .sequence(let commands):
            return commands.flatMap(\.authenticationCandidateRoutes)
        case .whenCancelled(let primary, fallback: let fallback):
            return primary.authenticationCandidateRoutes + fallback.authenticationCandidateRoutes
        case .pop, .popCount, .popToRoot:
            return []
        }
    }
}
