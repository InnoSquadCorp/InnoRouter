import Foundation
import OSLog

/// Resolves URLs by walking ``DeepLinkMapping`` values in declaration order.
///
/// - Important: A matcher checks the **path and query only**. It does not
///   inspect the scheme, host, user information, or port, so
///   `https://evil.example.com/home/detail/1` matches `/home/detail/:id`
///   exactly as a trusted origin would. ``DeepLinkOriginPolicy`` requires an
///   allowlist at every external URL entry point, and a bare matcher does not
///   provide one.
///
///   Prefer a surface that enforces the origin for you. `@DeepLink` on a
///   `@Router` case generates a `resolveDeepLink(_:)` that rejects user
///   information, explicit ports, and any scheme or host outside the
///   allowlist before matching, and `RouterLinkPipeline` applies
///   ``DeepLinkAdmission`` the same way. Reach for `DeepLinkMatcher` directly
///   only for URLs your own process constructed, or pair it with
///   ``DeepLinkAdmission`` yourself.
///
/// The output type describes what a matched URL produces. Use a route type for
/// single-route resolution, or `RouterPlan<R>` when one URL must rehydrate a
/// whole navigation state:
///
/// ```swift
/// let routeMatcher = DeepLinkMatcher<AppRoute> {
///     DeepLinkMapping("/home") { _ in .home }
/// }
///
/// let planMatcher = DeepLinkMatcher<RouterPlan<AppRoute>> {
///     DeepLinkMapping("/home/detail/:id") { parameters in
///         guard let id = parameters.firstValue(forName: "id") else { return nil }
///         return RouterPlan(state: .rootStack(path: [.home, .detail(id: id)]))
///     }
/// }
/// ```
///
/// When a pattern matches but its handler returns `nil`, matching continues
/// with the next declaration.
public struct DeepLinkMatcher<Output: Sendable>: Sendable {
    private let engine: DeepLinkMatchEngine<Output>

    /// Structural authoring diagnostics for this matcher's patterns.
    ///
    /// Computing these compares every pattern pair, so it is quadratic in
    /// catalog size. It is therefore done on demand rather than at
    /// construction: `@Router` builds a matcher inside each generated
    /// `resolveDeepLink` call, and charging that pass to every deep-link
    /// resolution cost ~620µs of a ~627µs resolution on a 60-case catalog.
    ///
    /// `.disabled` suppresses emission, not availability — this still reports
    /// the same diagnostics for a quiet matcher. Recomputed per access, so
    /// bind it to a local when inspecting it repeatedly.
    public var diagnostics: [DeepLinkMatcherDiagnostic] { engine.diagnostics }

    public init(
        configuration: DeepLinkMatcherConfiguration = .default,
        @DeepLinkMappingBuilder<Output> mappings: () -> [DeepLinkMapping<Output>]
    ) {
        let engine = DeepLinkMatchEngine(
            mappings: mappings().map(\.implementation),
            configuration: configuration
        )
        self.engine = engine
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
    }

    /// Returns the first mapping output whose pattern matches `url`.
    ///
    /// - Important: Matching covers the path and query only. The scheme, host,
    ///   user information, and port are never inspected, so this admits a URL
    ///   from any origin. See the type documentation for the surfaces that
    ///   enforce ``DeepLinkOriginPolicy`` before matching.
    public func match(_ url: URL) -> Output? {
        engine.match(url)
    }

    /// Returns the first mapping output whose pattern matches `urlString`.
    ///
    /// - Important: Matching covers the path and query only, and the origin is
    ///   never checked. See ``match(_:)-(URL)`` and the type documentation.
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
