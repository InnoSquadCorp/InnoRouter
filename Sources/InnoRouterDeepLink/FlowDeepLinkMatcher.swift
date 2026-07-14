// MARK: - FlowDeepLinkMatcher.swift
// InnoRouterDeepLink - URL → FlowPlan<R>? composite deep-link matching
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import OSLog
import InnoRouterCore

/// Resolves a URL to a ``FlowPlan`` that a `FlowStore` can apply in a
/// single coordinated step.
///
/// `FlowDeepLinkMapping` mirrors ``DeepLinkMapping`` but lets the
/// handler return a full `FlowPlan<R>` instead of a single `R`. This
/// keeps every multi-segment URL explicit at the call site — the
/// mapping author decides how many `RouteStep`s a URL expands into,
/// which makes push-prefix + modal-tail flows easy to declare:
///
/// ```swift
/// FlowDeepLinkMapping("/home") { _ in
///     FlowPlan(steps: [.push(.home)])
/// }
/// FlowDeepLinkMapping("/home/detail/:id") { params in
///     guard let id = params.firstValue(forName: "id") else { return nil }
///     return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
/// }
/// FlowDeepLinkMapping("/onboarding/privacy") { _ in
///     FlowPlan(steps: [.sheet(.privacyPolicy)])
/// }
/// ```
///
/// Pattern syntax (`:parameter`, terminal `*`) and parameter
/// extraction are identical to ``DeepLinkMatcher`` — the same
/// underlying ``DeepLinkPattern`` is reused.
public struct FlowDeepLinkMapping<R: Route>: Sendable {
    fileprivate let pattern: DeepLinkPattern
    private let handler: @Sendable (DeepLinkParameters) -> FlowPlan<R>?

    /// Creates a mapping from a pattern string plus a handler that
    /// builds the resulting `FlowPlan` from the extracted parameters.
    ///
    /// The handler returns `nil` to signal that the mapping did not
    /// recognise the parsed parameters (for example, a required path
    /// parameter was missing). Matching then falls through to the
    /// next declared mapping.
    public init(
        _ pattern: String,
        handler: @escaping @Sendable (DeepLinkParameters) -> FlowPlan<R>?
    ) {
        self.pattern = DeepLinkPattern(pattern)
        self.handler = handler
    }

    func match(_ parsed: DeepLinkParser.ParsedURL) -> FlowPlan<R>? {
        guard let result = pattern.match(parsed) else { return nil }
        return handler(DeepLinkParameters(valuesByName: result.parameters))
    }
}

/// Declarative matcher that walks a list of ``FlowDeepLinkMapping``
/// values in declaration order and returns the first match.
///
/// `FlowDeepLinkMatcher` is the flow-level counterpart to
/// ``DeepLinkMatcher``. The push-only matcher remains in place for
/// callers whose URLs only need single-route resolution; the two
/// matchers coexist so apps can adopt the flow matcher incrementally.
public struct FlowDeepLinkMatcher<R: Route>: Sendable {
    private let mappings: [FlowDeepLinkMapping<R>]
    private let inputLimits: DeepLinkInputLimits
    public let diagnostics: [DeepLinkMatcherDiagnostic]

    public init(@FlowDeepLinkMappingBuilder<R> mappings: () -> [FlowDeepLinkMapping<R>]) {
        self.init(configuration: .default, mappings: mappings)
    }

    public init(
        configuration: DeepLinkMatcherConfiguration = .default,
        @FlowDeepLinkMappingBuilder<R> mappings: () -> [FlowDeepLinkMapping<R>]
    ) {
        self.init(configuration: configuration, mappings: mappings())
    }

    public init(mappings: [FlowDeepLinkMapping<R>]) {
        self.init(configuration: .default, mappings: mappings)
    }

    public init(
        configuration: DeepLinkMatcherConfiguration = .default,
        mappings: [FlowDeepLinkMapping<R>]
    ) {
        self.mappings = mappings
        self.inputLimits = configuration.inputLimits
        self.diagnostics = DeepLinkPattern.makeDiagnostics(
            for: mappings.map(\.pattern)
        )
        DeepLinkMatcherDiagnostic.emit(self.diagnostics, configuration: configuration)
    }

    /// Creates a flow matcher that promotes any structural diagnostic into a
    /// thrown ``DeepLinkMatcherStrictError`` rather than emitting a warning.
    ///
    /// Use this in release-readiness gates where shipping shadowed or
    /// duplicated flow mappings would corrupt multi-step deep-link routing in
    /// production.
    public init(
        strict: Void = (),
        logger: Logger? = nil,
        inputLimits: DeepLinkInputLimits = .default,
        @FlowDeepLinkMappingBuilder<R> mappings: () -> [FlowDeepLinkMapping<R>]
    ) throws {
        try self.init(
            strict: strict,
            logger: logger,
            inputLimits: inputLimits,
            mappings: mappings()
        )
    }

    /// Creates a flow matcher from a mapping array and promotes any
    /// structural diagnostic into a thrown ``DeepLinkMatcherStrictError``.
    public init(
        strict: Void = (),
        logger: Logger? = nil,
        inputLimits: DeepLinkInputLimits = .default,
        mappings: [FlowDeepLinkMapping<R>]
    ) throws {
        let resolvedDiagnostics = DeepLinkPattern.makeDiagnostics(
            for: mappings.map(\.pattern)
        )
        if !resolvedDiagnostics.isEmpty {
            for diagnostic in resolvedDiagnostics {
                logger?.error("\(diagnostic.message, privacy: .public)")
            }
            throw DeepLinkMatcherStrictError(diagnostics: resolvedDiagnostics)
        }
        self.mappings = mappings
        self.inputLimits = inputLimits
        self.diagnostics = resolvedDiagnostics
    }

    /// Walks every declared mapping and returns the first plan that
    /// the URL matches, or `nil` if none apply.
    public func match(_ url: URL) -> FlowPlan<R>? {
        let parsed = DeepLinkParser.parse(url)
        guard inputLimits.violation(for: url, parsed: parsed) == nil else { return nil }
        return match(parsed: parsed)
    }

    /// Convenience overload for string URLs.
    public func match(_ urlString: String) -> FlowPlan<R>? {
        guard let url = URL(string: urlString) else { return nil }
        return match(url)
    }

    /// Pattern-walk without the input-limit gate, for pipeline callers
    /// that have already checked ``inputLimitViolation(for:parsed:)``
    /// against the same parsed value.
    func match(parsed: DeepLinkParser.ParsedURL) -> FlowPlan<R>? {
        for mapping in mappings {
            if let plan = mapping.match(parsed) {
                return plan
            }
        }
        return nil
    }

    func inputLimitViolation(
        for url: URL,
        parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkInputLimitViolation? {
        inputLimits.violation(for: url, parsed: parsed)
    }
}

/// Result-builder companion to ``FlowDeepLinkMatcher`` for DSL-style
/// authoring, mirroring ``DeepLinkMappingBuilder``.
@resultBuilder
public struct FlowDeepLinkMappingBuilder<R: Route> {
    public static func buildExpression(_ expression: FlowDeepLinkMapping<R>) -> FlowDeepLinkMapping<R> {
        expression
    }

    public static func buildBlock(_ components: FlowDeepLinkMapping<R>...) -> [FlowDeepLinkMapping<R>] {
        components
    }

    public static func buildArray(_ components: [[FlowDeepLinkMapping<R>]]) -> [FlowDeepLinkMapping<R>] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [FlowDeepLinkMapping<R>]?) -> [FlowDeepLinkMapping<R>] {
        component ?? []
    }

    public static func buildEither(first component: [FlowDeepLinkMapping<R>]) -> [FlowDeepLinkMapping<R>] {
        component
    }

    public static func buildEither(second component: [FlowDeepLinkMapping<R>]) -> [FlowDeepLinkMapping<R>] {
        component
    }
}
