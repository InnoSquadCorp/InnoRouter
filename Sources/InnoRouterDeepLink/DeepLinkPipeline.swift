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
    case inputLimitExceeded(DeepLinkInputLimitViolation)

    public var localizedDescription: String {
        switch self {
        case .schemeNotAllowed(let actualScheme):
            return "Deep-link scheme is not allowed: \(actualScheme ?? "nil")."
        case .hostNotAllowed(let actualHost):
            return "Deep-link host is not allowed: \(actualHost ?? "nil")."
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
    public typealias Resolver = @Sendable (URL) -> R?
    public typealias Planner = @Sendable (R) -> NavigationPlan<R>

    private let allowedSchemes: Set<String>?
    private let allowedHosts: Set<String>?
    private let resolve: Resolver
    private let authenticationPolicy: DeepLinkAuthenticationPolicy<R>
    private let plan: Planner
    private let inputLimits: DeepLinkInputLimits

    public init(
        allowedSchemes: Set<String>? = nil,
        allowedHosts: Set<String>? = nil,
        resolve: @escaping Resolver,
        authenticationPolicy: DeepLinkAuthenticationPolicy<R> = .notRequired,
        inputLimits: DeepLinkInputLimits = .default,
        plan: @escaping Planner = { route in NavigationPlan(commands: [.push(route)]) }
    ) {
        self.allowedSchemes = allowedSchemes?.lowercasedSet
        self.allowedHosts = allowedHosts?.lowercasedSet
        self.resolve = resolve
        self.authenticationPolicy = authenticationPolicy
        self.plan = plan
        self.inputLimits = inputLimits
    }

    public func decide(for url: URL) -> DeepLinkDecision<R> {
        if let violation = inputLimits.violation(for: url) {
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

        guard let route = resolve(url) else {
            return .unhandled(url: url)
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

private extension Set where Element == String {
    var lowercasedSet: Set<String> {
        Set(map { $0.lowercased() })
    }
}
