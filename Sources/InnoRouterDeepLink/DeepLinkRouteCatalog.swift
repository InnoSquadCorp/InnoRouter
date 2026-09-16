import Foundation

import InnoRouterCore

/// Type-identity checks used by generated catalogs to distinguish framework
/// conversions from application-owned `DeepLinkParameterValue` code.
public enum DeepLinkParameterConversionSupport {
    public static func isFrameworkOwned<Value>(_ type: Value.Type) -> Bool {
        let candidate: Any.Type = type
        return candidate == Swift.String.self
            || candidate == Swift.Int.self
            || candidate == Swift.Int8.self
            || candidate == Swift.Int16.self
            || candidate == Swift.Int32.self
            || candidate == Swift.Int64.self
            || candidate == Swift.UInt.self
            || candidate == Swift.UInt8.self
            || candidate == Swift.UInt16.self
            || candidate == Swift.UInt32.self
            || candidate == Swift.UInt64.self
            || candidate == Swift.Double.self
            || candidate == Swift.Float.self
            || candidate == Swift.Bool.self
            || candidate == Foundation.UUID.self
    }
}

/// Where a macro-declared deep-link parameter is read from.
public enum DeepLinkRouteParameterSource: String, Hashable, Sendable, Codable {
    case path
    case query
}

/// Payload-free schema for one macro-declared deep-link parameter.
public struct DeepLinkRouteParameterSchema: Hashable, Sendable, Codable {
    public let name: String
    public let typeName: String
    public let source: DeepLinkRouteParameterSource
    public let isRequired: Bool
    /// Whether parsing this value may invoke application-owned code.
    public let isApplicationConversionRequired: Bool

    public init(
        name: String,
        typeName: String,
        source: DeepLinkRouteParameterSource,
        isRequired: Bool,
        isApplicationConversionRequired: Bool = false
    ) {
        self.name = name
        self.typeName = typeName
        self.source = source
        self.isRequired = isRequired
        self.isApplicationConversionRequired = isApplicationConversionRequired
    }
}

/// One route-pattern entry generated from `@Router` and `@DeepLink`.
public struct DeepLinkRouteCatalogEntry: Identifiable, Hashable, Sendable, Codable {
    public let declarationNamespace: String
    public let featurePath: [String]
    public let routeCase: String
    public let pattern: String
    public let parameters: [DeepLinkRouteParameterSchema]

    public init(
        declarationNamespace: String = "",
        featurePath: [String] = [],
        routeCase: String,
        pattern: String,
        parameters: [DeepLinkRouteParameterSchema] = []
    ) {
        self.declarationNamespace = declarationNamespace
        self.featurePath = featurePath
        self.routeCase = routeCase
        self.pattern = pattern
        self.parameters = parameters
    }

    /// Stable payload-free identity across filtering and Inspector updates.
    public var id: String {
        ([declarationNamespace] + featurePath + [routeCase, pattern])
            .joined(separator: "::")
    }
}

public enum DeepLinkRouteAttemptOutcome: String, Hashable, Sendable, Codable {
    case pathMismatch
    case candidate
    case resolved
}

/// One ordered, payload-free matching attempt suitable for tests and tools.
public struct DeepLinkRouteAttempt: Hashable, Sendable, Codable {
    public let routeCase: String
    public let pattern: String
    public let outcome: DeepLinkRouteAttemptOutcome

    public init(routeCase: String, pattern: String, outcome: DeepLinkRouteAttemptOutcome) {
        self.routeCase = routeCase
        self.pattern = pattern
        self.outcome = outcome
    }
}

public enum DeepLinkResolutionFailure: Hashable, Sendable {
    /// Feature-graph traversal exceeded its bounded depth or work budget.
    case traversalLimitExceeded
    case credentialsNotAllowed
    case portNotAllowed
    case schemeNotAllowed(actual: String?)
    case hostNotAllowed(actual: String?)
    case inputLimitExceeded(DeepLinkInputLimitViolation)
    case noMatchingPattern
    case parameterConversionFailed(candidatePatterns: [String])
    case customResolverNotEvaluated
}

/// Complete explanation of origin admission and ordered pattern matching.
public struct DeepLinkResolutionExplanation: Hashable, Sendable {
    public enum Decision: Hashable, Sendable {
        case accepted(routeCase: String, pattern: String)
        case rejected(DeepLinkResolutionFailure)
    }

    public let decision: Decision
    public let attempts: [DeepLinkRouteAttempt]

    public init(decision: Decision, attempts: [DeepLinkRouteAttempt]) {
        self.decision = decision
        self.attempts = attempts
    }
}

/// Macro-generated catalog and deterministic deep-link explanation engine.
public struct DeepLinkRouteCatalog: Hashable, Sendable, Codable {
    public let schemes: [String]
    public let hosts: [String]
    public let entries: [DeepLinkRouteCatalogEntry]
    /// Whether traversal reached every feature branch represented by this catalog.
    ///
    /// An incomplete catalog never exposes partially collected entries. Its
    /// explanation rejects with ``DeepLinkResolutionFailure/traversalLimitExceeded``.
    public let isComplete: Bool

    public init(
        schemes: [String],
        hosts: [String],
        entries: [DeepLinkRouteCatalogEntry],
        isComplete: Bool = true
    ) {
        self.schemes = schemes
        self.hosts = hosts
        self.entries = isComplete ? entries : []
        self.isComplete = isComplete
    }

    /// Returns a child catalog embedded beneath one parent feature namespace.
    public func namespaced(
        declarationNamespace: String,
        featureID: String
    ) -> Self {
        .init(
            schemes: schemes,
            hosts: hosts,
            entries: entries.map { entry in
                .init(
                    declarationNamespace: declarationNamespace,
                    featurePath: [featureID] + entry.featurePath,
                    routeCase: featureID + "." + entry.routeCase,
                    pattern: entry.pattern,
                    parameters: entry.parameters
                )
            },
            isComplete: isComplete
        )
    }

    public func merging(_ other: Self) -> Self {
        let isComplete = isComplete && other.isComplete
        return .init(
            schemes: Self.uniqueCaseInsensitive(schemes + other.schemes),
            hosts: Self.uniqueCaseInsensitive(hosts + other.hosts),
            entries: isComplete ? entries + other.entries : [],
            isComplete: isComplete
        )
    }

    /// Returns whether all matching candidates can be resolved using only
    /// framework-owned parameter conversions.
    public func supportsPureResolution(
        of url: URL,
        inputLimits: DeepLinkInputLimits = .default
    ) -> Bool {
        guard isComplete,
              url.user == nil, url.password == nil, url.port == nil,
              let scheme = url.scheme,
              schemes.contains(where: { $0.caseInsensitiveCompare(scheme) == .orderedSame }),
              let host = url.host,
              hosts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }),
              inputLimits.violation(for: url) == nil else {
            return false
        }
        let parsed = DeepLinkParser.parse(url)
        let candidates = entries.filter { DeepLinkPattern($0.pattern).match(parsed) != nil }
        return !candidates.isEmpty && candidates.allSatisfy { entry in
            entry.parameters.allSatisfy { !$0.isApplicationConversionRequired }
        }
    }

    public func explain<R: Route>(
        _ url: URL,
        inputLimits: DeepLinkInputLimits = .default,
        shouldResolve: Bool = true,
        resolve: (URL) -> R?,
        resolvedCaseName: (R) -> String? = { _ in nil }
    ) -> DeepLinkResolutionExplanation {
        guard isComplete else {
            return .init(decision: .rejected(.traversalLimitExceeded), attempts: [])
        }
        guard url.user == nil, url.password == nil else {
            return .init(decision: .rejected(.credentialsNotAllowed), attempts: [])
        }
        guard url.port == nil else {
            return .init(decision: .rejected(.portNotAllowed), attempts: [])
        }
        guard let scheme = url.scheme,
              schemes.contains(where: { $0.caseInsensitiveCompare(scheme) == .orderedSame }) else {
            return .init(
                decision: .rejected(.schemeNotAllowed(actual: url.scheme)),
                attempts: []
            )
        }
        guard let host = url.host,
              hosts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) else {
            return .init(
                decision: .rejected(.hostNotAllowed(actual: url.host)),
                attempts: []
            )
        }
        if let violation = inputLimits.violation(for: url) {
            return .init(decision: .rejected(.inputLimitExceeded(violation)), attempts: [])
        }

        let parsed = DeepLinkParser.parse(url)
        let candidates = entries.filter { DeepLinkPattern($0.pattern).match(parsed) != nil }
        guard shouldResolve else {
            let attempts = entries.map { entry in
                DeepLinkRouteAttempt(
                    routeCase: entry.routeCase,
                    pattern: entry.pattern,
                    outcome: candidates.contains(entry) ? .candidate : .pathMismatch
                )
            }
            return .init(decision: .rejected(.customResolverNotEvaluated), attempts: attempts)
        }
        guard let resolved = resolve(url) else {
            let attempts = entries.map { entry in
                DeepLinkRouteAttempt(
                    routeCase: entry.routeCase,
                    pattern: entry.pattern,
                    outcome: candidates.contains(entry) ? .candidate : .pathMismatch
                )
            }
            let failure: DeepLinkResolutionFailure = candidates.isEmpty
                ? .noMatchingPattern
                : .parameterConversionFailed(candidatePatterns: candidates.map(\.pattern))
            return .init(decision: .rejected(failure), attempts: attempts)
        }

        let caseName = resolvedCaseName(resolved)
        let matched = candidates.first(where: { $0.routeCase == caseName }) ?? candidates.first
        var attempts = entries.prefix { $0 != matched }.map { entry in
            DeepLinkRouteAttempt(
                routeCase: entry.routeCase,
                pattern: entry.pattern,
                outcome: candidates.contains(entry) ? .candidate : .pathMismatch
            )
        }
        if let matched {
            attempts.append(.init(
                routeCase: matched.routeCase,
                pattern: matched.pattern,
                outcome: .resolved
            ))
        }
        return .init(
            decision: .accepted(
                routeCase: matched?.routeCase ?? String(reflecting: R.self),
                pattern: matched?.pattern ?? "<custom-resolver>"
            ),
            attempts: attempts
        )
    }

    private static func uniqueCaseInsensitive(_ values: [String]) -> [String] {
        var observed: Set<String> = []
        return values.filter { observed.insert($0.lowercased()).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case schemes
        case hosts
        case entries
        case isComplete
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemes = try container.decode([String].self, forKey: .schemes)
        let hosts = try container.decode([String].self, forKey: .hosts)
        let entries = try container.decode([DeepLinkRouteCatalogEntry].self, forKey: .entries)
        let isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
        self.init(schemes: schemes, hosts: hosts, entries: entries, isComplete: isComplete)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemes, forKey: .schemes)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(entries, forKey: .entries)
        if !isComplete {
            try container.encode(false, forKey: .isComplete)
        }
    }
}
