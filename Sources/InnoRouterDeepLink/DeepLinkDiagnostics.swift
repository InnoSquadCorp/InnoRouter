import Foundation
import OSLog

private let defaultDeepLinkMatcherLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "deep-link-matcher"
)

/// Controls how `DeepLinkMatcher` surfaces structural diagnostics.
///
/// Strict-mode diagnostic promotion is intentionally not a case on this
/// enum; promotion is only available through the throwing
/// ``DeepLinkMatcher/init(strict:logger:inputLimits:mappings:)``
/// initializer, which validates without going through
/// `DeepLinkMatcherConfiguration` at all. Splitting the diagnostics
/// surface this way removes a previous
/// release-crash trap where a non-throwing init paired with a `.strict`
/// configuration would `preconditionFailure` at runtime.
public enum DeepLinkMatcherDiagnosticsMode: Sendable, Equatable {
    /// Disables matcher diagnostics.
    case disabled
    /// Emits warning diagnostics during matcher construction without failing execution.
    case debugWarnings
}

/// Error thrown by strict matcher initializers when a structural
/// diagnostic is encountered.
public struct DeepLinkMatcherStrictError: Error, Sendable, Equatable {
    /// The diagnostics that triggered the failure.
    ///
    /// Strict matcher initializers only throw this error with a non-empty
    /// collection.
    public let diagnostics: [DeepLinkMatcherDiagnostic]

    init(diagnostics: [DeepLinkMatcherDiagnostic]) {
        self.diagnostics = diagnostics
    }
}

/// Describes a structural issue detected while building a `DeepLinkMatcher`.
public enum DeepLinkMatcherDiagnostic: Sendable, Equatable {
    /// Indicates that a `*` wildcard appears before the final path segment.
    case nonTerminalWildcard(pattern: String, index: Int)
    /// Indicates that the same normalized pattern was declared more than once.
    case duplicatePattern(pattern: String, firstIndex: Int, duplicateIndex: Int)
    /// Indicates that an earlier wildcard pattern shadows a later mapping.
    case wildcardShadowing(
        pattern: String,
        index: Int,
        shadowedPattern: String,
        shadowedIndex: Int
    )
    /// Indicates that an earlier parameterized pattern shadows a more specific mapping.
    case parameterShadowing(
        pattern: String,
        index: Int,
        shadowedPattern: String,
        shadowedIndex: Int
    )
    /// Indicates that a `:parameter` segment has an invalid Swift-like
    /// identifier name.
    case invalidParameterName(pattern: String, index: Int, name: String)

    /// A human-readable diagnostic message suitable for logs or debug output.
    public var message: String {
        switch self {
        case .nonTerminalWildcard(let pattern, let index):
            return "DeepLinkMatcher pattern '\(pattern)' declares a wildcard at segment \(index), but wildcards must be terminal."
        case .duplicatePattern(let pattern, let firstIndex, let duplicateIndex):
            return "DeepLinkMatcher duplicate pattern '\(pattern)' at indices \(firstIndex) and \(duplicateIndex)."
        case .wildcardShadowing(let pattern, let index, let shadowedPattern, let shadowedIndex):
            return "DeepLinkMatcher pattern '\(pattern)' at index \(index) shadows '\(shadowedPattern)' at index \(shadowedIndex) because its wildcard matches first."
        case .parameterShadowing(let pattern, let index, let shadowedPattern, let shadowedIndex):
            return "DeepLinkMatcher pattern '\(pattern)' at index \(index) shadows more specific pattern '\(shadowedPattern)' at index \(shadowedIndex)."
        case .invalidParameterName(let pattern, let index, let name):
            return "DeepLinkMatcher pattern '\(pattern)' declares invalid parameter name '\(name)' at segment \(index). Parameter names must match ^[A-Za-z_][A-Za-z0-9_]*$."
        }
    }
}

extension DeepLinkMatcherDiagnostic {
    package init(_ diagnostic: RoutePatternDiagnostic) {
        switch diagnostic {
        case .nonTerminalWildcard(let pattern, let index):
            self = .nonTerminalWildcard(pattern: pattern, index: index)
        case .duplicatePattern(let pattern, let firstIndex, let duplicateIndex):
            self = .duplicatePattern(
                pattern: pattern,
                firstIndex: firstIndex,
                duplicateIndex: duplicateIndex
            )
        case .wildcardShadowing(let pattern, let index, let shadowedPattern, let shadowedIndex):
            self = .wildcardShadowing(
                pattern: pattern,
                index: index,
                shadowedPattern: shadowedPattern,
                shadowedIndex: shadowedIndex
            )
        case .parameterShadowing(let pattern, let index, let shadowedPattern, let shadowedIndex):
            self = .parameterShadowing(
                pattern: pattern,
                index: index,
                shadowedPattern: shadowedPattern,
                shadowedIndex: shadowedIndex
            )
        case .invalidParameterName(let pattern, let index, let name):
            self = .invalidParameterName(pattern: pattern, index: index, name: name)
        }
    }
}

/// Input-size guardrails applied before deep-link matching.
public struct DeepLinkInputLimits: Sendable, Equatable {
    public var maxURLLength: Int?
    public var maxPathSegments: Int?
    public var maxQueryItems: Int?

    public init(
        maxURLLength: Int? = 8_192,
        maxPathSegments: Int? = 128,
        maxQueryItems: Int? = 256
    ) {
        self.maxURLLength = maxURLLength
        self.maxPathSegments = maxPathSegments
        self.maxQueryItems = maxQueryItems
    }

    public static let `default` = DeepLinkInputLimits()
    public static let unlimited = DeepLinkInputLimits(
        maxURLLength: nil,
        maxPathSegments: nil,
        maxQueryItems: nil
    )

    public func violation(for url: URL) -> DeepLinkInputLimitViolation? {
        if let violation = urlLengthViolation(for: url) {
            return violation
        }
        return parsedContentViolation(for: DeepLinkParser.parse(url))
    }

    /// Checks the raw URL before parsing so the length limit remains a
    /// resource guard for untrusted, oversized input.
    func urlLengthViolation(for url: URL) -> DeepLinkInputLimitViolation? {
        if let maxURLLength, url.absoluteString.count > maxURLLength {
            return .urlLengthExceeded(actual: url.absoluteString.count, max: maxURLLength)
        }
        return nil
    }

    /// Checks limits that require an already-parsed URL. Matchers and
    /// pipelines share one parsed value between this check and pattern
    /// matching, while oversized raw URLs are rejected before parsing.
    func parsedContentViolation(
        for parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkInputLimitViolation? {
        if let maxPathSegments, parsed.path.count > maxPathSegments {
            return .pathSegmentCountExceeded(actual: parsed.path.count, max: maxPathSegments)
        }
        if let maxQueryItems {
            let queryItemCount = parsed.queryItems.values.reduce(0) { $0 + $1.count }
            if queryItemCount > maxQueryItems {
                return .queryItemCountExceeded(actual: queryItemCount, max: maxQueryItems)
            }
        }
        return nil
    }
}

public enum DeepLinkInputLimitViolation: Sendable, Equatable {
    case urlLengthExceeded(actual: Int, max: Int)
    case pathSegmentCountExceeded(actual: Int, max: Int)
    case queryItemCountExceeded(actual: Int, max: Int)

    public var localizedDescription: String {
        switch self {
        case .urlLengthExceeded(let actual, let max):
            return "Deep-link URL is too long (\(actual) characters, maximum \(max))."
        case .pathSegmentCountExceeded(let actual, let max):
            return "Deep-link path has too many segments (\(actual), maximum \(max))."
        case .queryItemCountExceeded(let actual, let max):
            return "Deep-link query has too many items (\(actual), maximum \(max))."
        }
    }
}

/// Configuration for matcher diagnostics and logging.
public struct DeepLinkMatcherConfiguration: Sendable {
    /// Diagnostic emission mode used during matcher construction.
    public var diagnosticsMode: DeepLinkMatcherDiagnosticsMode
    /// Optional logger for diagnostic output. Pass `nil` to keep diagnostics
    /// available through the matcher without emitting them to OSLog.
    public var logger: Logger?
    /// Optional input-size limits enforced by matcher `match` calls.
    public var inputLimits: DeepLinkInputLimits

    /// Creates a matcher configuration.
    public init(
        diagnosticsMode: DeepLinkMatcherDiagnosticsMode,
        logger: Logger? = nil,
        inputLimits: DeepLinkInputLimits = .default
    ) {
        self.diagnosticsMode = diagnosticsMode
        self.logger = logger
        self.inputLimits = inputLimits
    }

    /// Emits structural authoring warnings through the package OSLog category.
    public static var `default`: Self {
        .init(
            diagnosticsMode: .debugWarnings,
            logger: defaultDeepLinkMatcherLogger
        )
    }
}
