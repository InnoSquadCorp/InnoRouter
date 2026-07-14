import Foundation
import OSLog

import InnoRouterCore

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
    /// collection, but the public initializer accepts any array so tests and
    /// custom validators cannot accidentally crash the host app.
    public let diagnostics: [DeepLinkMatcherDiagnostic]

    public init(diagnostics: [DeepLinkMatcherDiagnostic]) {
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
        violation(for: url, parsed: DeepLinkParser.parse(url))
    }

    /// Parse-free variant for callers that already hold the URL's
    /// ``DeepLinkParser/ParsedURL``. Matchers and pipelines thread one
    /// parsed value through limit checks and pattern matching so a
    /// single deep-link decision parses its URL exactly once.
    func violation(
        for url: URL,
        parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkInputLimitViolation? {
        if let maxURLLength, url.absoluteString.count > maxURLLength {
            return .urlLengthExceeded(actual: url.absoluteString.count, max: maxURLLength)
        }
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
    /// Optional logger for diagnostic output.
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

    public static var `default`: Self { .init(diagnosticsMode: .debugWarnings) }
}

/// Parses a string captured from a deep-link path or query item into a typed value.
public protocol DeepLinkParameterValue: Sendable {
    /// Returns a typed value for a raw deep-link parameter string, or `nil`
    /// when the value cannot be represented by the conforming type.
    static func parseDeepLinkParameter(_ value: String) -> Self?
}

extension String: DeepLinkParameterValue {
    /// Returns the captured value unchanged.
    public static func parseDeepLinkParameter(_ value: String) -> String? {
        value
    }
}

extension Int: DeepLinkParameterValue {
    /// Parses a base-10 signed integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int? {
        Int(value)
    }
}

extension Int8: DeepLinkParameterValue {
    /// Parses a base-10 signed 8-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int8? {
        Int8(value)
    }
}

extension Int16: DeepLinkParameterValue {
    /// Parses a base-10 signed 16-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int16? {
        Int16(value)
    }
}

extension Int32: DeepLinkParameterValue {
    /// Parses a base-10 signed 32-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int32? {
        Int32(value)
    }
}

extension Int64: DeepLinkParameterValue {
    /// Parses a base-10 signed 64-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Int64? {
        Int64(value)
    }
}

extension UInt: DeepLinkParameterValue {
    /// Parses a base-10 unsigned integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt? {
        UInt(value)
    }
}

extension UInt8: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 8-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt8? {
        UInt8(value)
    }
}

extension UInt16: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 16-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt16? {
        UInt16(value)
    }
}

extension UInt32: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 32-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt32? {
        UInt32(value)
    }
}

extension UInt64: DeepLinkParameterValue {
    /// Parses a base-10 unsigned 64-bit integer from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> UInt64? {
        UInt64(value)
    }
}

extension Double: DeepLinkParameterValue {
    /// Parses a double-precision floating-point value from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Double? {
        Double(value)
    }
}

extension Float: DeepLinkParameterValue {
    /// Parses a single-precision floating-point value from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Float? {
        Float(value)
    }
}

extension Bool: DeepLinkParameterValue {
    /// Parses Swift's standard Boolean literals from the captured value.
    public static func parseDeepLinkParameter(_ value: String) -> Bool? {
        Bool(value)
    }
}

extension UUID: DeepLinkParameterValue {
    /// Parses a UUID from the captured value's string representation.
    public static func parseDeepLinkParameter(_ value: String) -> UUID? {
        UUID(uuidString: value)
    }
}

public struct DeepLinkParameters: Sendable, Equatable {
    public let valuesByName: [String: [String]]

    public init(valuesByName: [String: [String]] = [:]) {
        self.valuesByName = valuesByName
    }

    public var firstValuesByName: [String: String] {
        valuesByName.compactMapValues { $0.first }
    }

    public func firstValue(forName name: String) -> String? {
        valuesByName[name]?.first
    }

    /// Returns the first captured value for `name` parsed as `Value`.
    ///
    /// Returns `nil` when the parameter is missing or the first captured
    /// string cannot be represented by `Value`.
    public func firstValue<Value: DeepLinkParameterValue>(
        forName name: String,
        as type: Value.Type = Value.self
    ) -> Value? {
        _ = type
        guard let value = firstValue(forName: name) else { return nil }
        return Value.parseDeepLinkParameter(value)
    }

    public func values(forName name: String) -> [String] {
        valuesByName[name] ?? []
    }

    /// Returns all captured values for `name` that can be parsed as `Value`.
    ///
    /// Missing parameters return an empty array. Individual values that cannot
    /// be represented by `Value` are skipped.
    public func values<Value: DeepLinkParameterValue>(
        forName name: String,
        as type: Value.Type = Value.self
    ) -> [Value] {
        _ = type
        return values(forName: name).compactMap(Value.parseDeepLinkParameter)
    }
}

public struct DeepLinkParser: Sendable {
    public struct ParsedURL: Sendable, Equatable {
        public let scheme: String?
        public let host: String?
        public let path: [String]
        public let queryItems: [String: [String]]
        public let fragment: String?

        public init(url: URL) {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            self.scheme = components?.scheme
            self.host = components?.host
            // Normalise percent-encoded segments (for example
            // `hello%20world` -> `hello world`, or any non-ASCII path
            // segment such as `%E2%9C%93` -> a literal check mark) so
            // that human-readable patterns declared in `DeepLinkMapping`
            // match their URL-encoded counterparts. `URL.pathComponents`
            // may return raw or decoded components depending on the URL
            // form; applying `removingPercentEncoding` defensively keeps
            // the contract platform-stable.
            self.path = url.pathComponents
                .filter { $0 != "/" }
                .map { component in
                    component.removingPercentEncoding ?? component
                }

            var parsedQueryItems: [String: [String]] = [:]
            for item in components?.queryItems ?? [] {
                parsedQueryItems[item.name, default: []].append(item.value ?? "")
            }
            self.queryItems = parsedQueryItems

            self.fragment = components?.fragment
        }

        public var pathString: String {
            "/" + path.joined(separator: "/")
        }

        public var firstQueryItems: [String: String] {
            queryItems.compactMapValues { $0.first }
        }
    }

    public static func parse(_ urlString: String) -> ParsedURL? {
        guard let url = URL(string: urlString) else { return nil }
        return ParsedURL(url: url)
    }

    public static func parse(_ url: URL) -> ParsedURL {
        ParsedURL(url: url)
    }
}

public struct DeepLinkPattern: Sendable {
    public struct MatchResult: Sendable {
        public let parameters: [String: [String]]
        public let isMatched: Bool

        public init(parameters: [String: [String]] = [:], isMatched: Bool = true) {
            self.parameters = parameters
            self.isMatched = isMatched
        }

        public static let noMatch = MatchResult(isMatched: false)
    }

    fileprivate let rawPattern: String
    fileprivate let patternParts: [PatternPart]

    fileprivate enum PatternPart: Sendable, Equatable {
        case literal(String)
        case parameter(String)
        case wildcard

        func covers(_ other: Self) -> Bool {
            switch (self, other) {
            case (.literal(let lhs), .literal(let rhs)):
                return lhs == rhs
            case (.parameter, .literal), (.parameter, .parameter):
                return true
            case (.wildcard, _):
                return true
            default:
                return false
            }
        }
    }

    public init(_ pattern: String) {
        self.rawPattern = pattern
        self.patternParts = pattern
            .split(separator: "/")
            .map { part -> PatternPart in
                let stringPart = String(part)
                if stringPart.hasPrefix(":") {
                    return .parameter(String(stringPart.dropFirst()))
                } else if stringPart == "*" {
                    return .wildcard
                } else {
                    return .literal(stringPart)
                }
            }
    }

    public func match(_ path: String) -> MatchResult? {
        guard nonTerminalWildcardIndex == nil else { return nil }
        guard invalidParameterNameDiagnostics.isEmpty else { return nil }

        let pathParts = path.split(separator: "/").map(String.init)

        let hasWildcard = patternParts.contains { part in
            if case .wildcard = part { return true }
            return false
        }
        if !hasWildcard && patternParts.count != pathParts.count {
            return nil
        }

        var parameters: [String: [String]] = [:]

        for (index, patternPart) in patternParts.enumerated() {
            switch patternPart {
            case .literal(let expected):
                guard index < pathParts.count, pathParts[index] == expected else { return nil }

            case .parameter(let name):
                guard index < pathParts.count else { return nil }
                parameters[name, default: []].append(pathParts[index])

            case .wildcard:
                return MatchResult(parameters: parameters)
            }
        }

        return MatchResult(parameters: parameters)
    }

    public func match(_ parsed: DeepLinkParser.ParsedURL) -> MatchResult? {
        guard let result = match(parsed.pathString) else { return nil }
        let mergedParameters = Self.merge(result.parameters, with: parsed.queryItems)
        return MatchResult(parameters: mergedParameters)
    }

    private static func merge(
        _ first: [String: [String]],
        with second: [String: [String]]
    ) -> [String: [String]] {
        var merged = first
        for (key, values) in second {
            merged[key, default: []].append(contentsOf: values)
        }
        return merged
    }

    fileprivate var normalizedPattern: String {
        "/" + patternParts.map { part in
            switch part {
            case .literal(let value):
                return value
            case .parameter:
                return ":param"
            case .wildcard:
                return "*"
            }
        }.joined(separator: "/")
    }

    fileprivate var wildcardIndex: Int? {
        patternParts.firstIndex(of: .wildcard)
    }

    fileprivate var nonTerminalWildcardIndex: Int? {
        guard let wildcardIndex, wildcardIndex != patternParts.index(before: patternParts.endIndex) else {
            return nil
        }
        return wildcardIndex
    }

    fileprivate var invalidParameterNameDiagnostics: [DeepLinkMatcherDiagnostic] {
        patternParts.enumerated().compactMap { index, part in
            guard case .parameter(let name) = part,
                  !Self.isValidParameterName(name)
            else {
                return nil
            }
            return .invalidParameterName(
                pattern: rawPattern,
                index: index,
                name: name
            )
        }
    }

    private static func isValidParameterName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        guard isASCIILetter(first) || first == "_" else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy { scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_"
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48 ... 57).contains(scalar.value)
    }

    fileprivate func shadows(_ other: DeepLinkPattern) -> DeepLinkMatcherDiagnostic.Kind? {
        guard nonTerminalWildcardIndex == nil else {
            return nil
        }

        if let wildcardIndex {
            guard prefixStructurallyCovers(other.patternParts, prefixLength: wildcardIndex) else {
                return nil
            }
            return .wildcard
        }

        guard patternParts.count == other.patternParts.count else {
            return nil
        }

        var sawParameterShadow = false
        for (lhs, rhs) in zip(patternParts, other.patternParts) {
            switch (lhs, rhs) {
            case (.literal(let lhsValue), .literal(let rhsValue)) where lhsValue == rhsValue:
                continue
            case (.parameter, .literal):
                sawParameterShadow = true
            case (.parameter(let lhsName), .parameter(let rhsName)):
                sawParameterShadow = sawParameterShadow || lhsName != rhsName
                continue
            default:
                return nil
            }
        }

        return sawParameterShadow ? .parameter : nil
    }

    private func prefixStructurallyCovers(
        _ otherParts: [PatternPart],
        prefixLength: Int
    ) -> Bool {
        guard otherParts.count >= prefixLength else {
            return false
        }

        for index in 0..<prefixLength {
            guard patternParts[index].covers(otherParts[index]) else {
                return false
            }
        }
        return true
    }

    static func makeDiagnostics(
        for patterns: [DeepLinkPattern]
    ) -> [DeepLinkMatcherDiagnostic] {
        var diagnostics: [DeepLinkMatcherDiagnostic] = []

        for index in patterns.indices {
            let pattern = patterns[index]
            if let wildcardIndex = pattern.nonTerminalWildcardIndex {
                diagnostics.append(
                    .nonTerminalWildcard(
                        pattern: pattern.normalizedPattern,
                        index: wildcardIndex
                    )
                )
            }
            diagnostics.append(contentsOf: pattern.invalidParameterNameDiagnostics)
        }

        for earlierIndex in patterns.indices {
            let earlier = patterns[earlierIndex]
            guard earlier.nonTerminalWildcardIndex == nil else {
                continue
            }
            for laterIndex in patterns.indices where laterIndex > earlierIndex {
                let later = patterns[laterIndex]
                guard later.nonTerminalWildcardIndex == nil else {
                    continue
                }

                if earlier.normalizedPattern == later.normalizedPattern {
                    diagnostics.append(
                        .duplicatePattern(
                            pattern: later.normalizedPattern,
                            firstIndex: earlierIndex,
                            duplicateIndex: laterIndex
                        )
                    )
                    continue
                }

                switch earlier.shadows(later) {
                case .wildcard?:
                    diagnostics.append(
                        .wildcardShadowing(
                            pattern: earlier.normalizedPattern,
                            index: earlierIndex,
                            shadowedPattern: later.normalizedPattern,
                            shadowedIndex: laterIndex
                        )
                    )
                case .parameter?:
                    diagnostics.append(
                        .parameterShadowing(
                            pattern: earlier.normalizedPattern,
                            index: earlierIndex,
                            shadowedPattern: later.normalizedPattern,
                            shadowedIndex: laterIndex
                        )
                    )
                case nil:
                    break
                }
            }
        }

        return diagnostics
    }
}

public struct DeepLinkMatcher<R: Route>: Sendable {
    private let mappings: [DeepLinkMapping<R>]
    private let inputLimits: DeepLinkInputLimits
    public let diagnostics: [DeepLinkMatcherDiagnostic]

    public init(@DeepLinkMappingBuilder<R> mappings: () -> [DeepLinkMapping<R>]) {
        self.init(configuration: .default, mappings: mappings)
    }

    public init(
        configuration: DeepLinkMatcherConfiguration = .default,
        @DeepLinkMappingBuilder<R> mappings: () -> [DeepLinkMapping<R>]
    ) {
        let resolvedMappings = mappings()
        self.mappings = resolvedMappings
        self.inputLimits = configuration.inputLimits
        self.diagnostics = DeepLinkPattern.makeDiagnostics(
            for: resolvedMappings.map(\.pattern)
        )
        DeepLinkMatcherDiagnostic.emit(self.diagnostics, configuration: configuration)
    }

    /// Creates a matcher that promotes any structural diagnostic into a
    /// thrown ``DeepLinkMatcherStrictError`` rather than emitting a warning.
    ///
    /// Use this in release builds or release-readiness gates where shipping
    /// shadowed / duplicated patterns would corrupt deep-link routing in
    /// production. The diagnostics that triggered the failure are surfaced
    /// in the thrown error so callers can produce actionable messages.
    public init(
        strict: Void = (),
        logger: Logger? = nil,
        inputLimits: DeepLinkInputLimits = .default,
        @DeepLinkMappingBuilder<R> mappings: () -> [DeepLinkMapping<R>]
    ) throws {
        let resolvedMappings = mappings()
        let resolvedDiagnostics = DeepLinkPattern.makeDiagnostics(
            for: resolvedMappings.map(\.pattern)
        )
        if !resolvedDiagnostics.isEmpty {
            // Surface the diagnostics through the optional logger before
            // throwing so a CI run still has the structured warning trail.
            for diagnostic in resolvedDiagnostics {
                logger?.error("\(diagnostic.message, privacy: .public)")
            }
            throw DeepLinkMatcherStrictError(diagnostics: resolvedDiagnostics)
        }
        self.mappings = resolvedMappings
        self.inputLimits = inputLimits
        self.diagnostics = resolvedDiagnostics
    }

    public func match(_ url: URL) -> R? {
        let parsed = DeepLinkParser.parse(url)
        guard inputLimits.violation(for: url, parsed: parsed) == nil else { return nil }
        for mapping in mappings {
            if let route = mapping.match(parsed) {
                return route
            }
        }
        return nil
    }

    public func match(_ urlString: String) -> R? {
        guard let url = URL(string: urlString) else { return nil }
        return match(url)
    }
}

public struct DeepLinkMapping<R: Route>: Sendable {
    fileprivate let pattern: DeepLinkPattern
    private let handler: @Sendable (DeepLinkParameters) -> R?

    public init(
        _ pattern: String,
        handler: @escaping @Sendable (DeepLinkParameters) -> R?
    ) {
        self.pattern = DeepLinkPattern(pattern)
        self.handler = handler
    }

    func match(_ parsed: DeepLinkParser.ParsedURL) -> R? {
        guard let result = pattern.match(parsed) else { return nil }
        return handler(DeepLinkParameters(valuesByName: result.parameters))
    }
}

public extension DeepLinkMatcherDiagnostic {
    enum Kind: Sendable, Equatable {
        case wildcard
        case parameter
    }
}

extension DeepLinkMatcherDiagnostic {
    static func emit(
        _ diagnostics: [DeepLinkMatcherDiagnostic],
        configuration: DeepLinkMatcherConfiguration
    ) {
        switch configuration.diagnosticsMode {
        case .disabled:
            return
        case .debugWarnings:
            for diagnostic in diagnostics {
                configuration.logger?.warning("\(diagnostic.message, privacy: .public)")
            }
        }
    }
}

@resultBuilder
public struct DeepLinkMappingBuilder<R: Route> {
    public static func buildExpression(_ expression: DeepLinkMapping<R>) -> DeepLinkMapping<R> {
        expression
    }

    public static func buildBlock(_ components: DeepLinkMapping<R>...) -> [DeepLinkMapping<R>] {
        components
    }

    public static func buildArray(_ components: [[DeepLinkMapping<R>]]) -> [DeepLinkMapping<R>] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [DeepLinkMapping<R>]?) -> [DeepLinkMapping<R>] {
        component ?? []
    }

    public static func buildEither(first component: [DeepLinkMapping<R>]) -> [DeepLinkMapping<R>] {
        component
    }

    public static func buildEither(second component: [DeepLinkMapping<R>]) -> [DeepLinkMapping<R>] {
        component
    }
}
