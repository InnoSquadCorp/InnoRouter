import Foundation
import OSLog

/// Resolves URLs by walking ``DeepLinkMapping`` values in declaration order.
///
/// The output type describes what a matched URL produces. Use a route type
/// for single-route resolution, or `FlowPlan<R>` when one URL must
/// rehydrate a push prefix plus a modal tail:
///
/// ```swift
/// let routeMatcher = DeepLinkMatcher<AppRoute> {
///     DeepLinkMapping("/home") { _ in .home }
/// }
///
/// let flowMatcher = DeepLinkMatcher<FlowPlan<AppRoute>> {
///     DeepLinkMapping("/home/detail/:id") { parameters in
///         guard let id = parameters.firstValue(forName: "id") else { return nil }
///         return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
///     }
/// }
/// ```
///
/// When a pattern matches but its handler returns `nil`, matching continues
/// with the next declaration.
public struct DeepLinkMatcher<Output: Sendable>: Sendable {
    private let engine: DeepLinkMatchEngine<Output>
    public let diagnostics: [DeepLinkMatcherDiagnostic]

    public init(
        configuration: DeepLinkMatcherConfiguration = .default,
        @DeepLinkMappingBuilder<Output> mappings: () -> [DeepLinkMapping<Output>]
    ) {
        let engine = DeepLinkMatchEngine(
            mappings: mappings().map(\.implementation),
            configuration: configuration
        )
        self.engine = engine
        self.diagnostics = engine.diagnostics
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
        @DeepLinkMappingBuilder<Output> mappings: () -> [DeepLinkMapping<Output>]
    ) throws {
        _ = strict
        let engine = try DeepLinkMatchEngine(
            validating: mappings().map(\.implementation),
            logger: logger,
            inputLimits: inputLimits
        )
        self.engine = engine
        self.diagnostics = engine.diagnostics
    }

    public func match(_ url: URL) -> Output? {
        engine.match(url)
    }

    public func match(_ urlString: String) -> Output? {
        engine.match(urlString)
    }

    /// Atomic matcher evaluation for module-internal callers that already parsed
    /// the same URL instance.
    func evaluate(
        _ url: URL,
        parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkMatchEvaluation<Output> {
        engine.evaluate(url, parsed: parsed)
    }
}

/// Associates one URL path pattern with a typed output builder.
public struct DeepLinkMapping<Output: Sendable>: Sendable {
    let implementation: DeepLinkMatchMapping<Output>

    public init(
        _ pattern: String,
        handler: @escaping @Sendable (DeepLinkParameters) -> Output?
    ) {
        self.implementation = DeepLinkMatchMapping(pattern, handler: handler)
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
public struct DeepLinkMappingBuilder<Output: Sendable> {
    public static func buildExpression(_ expression: DeepLinkMapping<Output>) -> [DeepLinkMapping<Output>] {
        [expression]
    }

    public static func buildExpression(_ expression: [DeepLinkMapping<Output>]) -> [DeepLinkMapping<Output>] {
        expression
    }

    public static func buildBlock(_ components: [DeepLinkMapping<Output>]...) -> [DeepLinkMapping<Output>] {
        components.flatMap { $0 }
    }

    public static func buildArray(_ components: [[DeepLinkMapping<Output>]]) -> [DeepLinkMapping<Output>] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [DeepLinkMapping<Output>]?) -> [DeepLinkMapping<Output>] {
        component ?? []
    }

    public static func buildEither(first component: [DeepLinkMapping<Output>]) -> [DeepLinkMapping<Output>] {
        component
    }

    public static func buildEither(second component: [DeepLinkMapping<Output>]) -> [DeepLinkMapping<Output>] {
        component
    }
}
