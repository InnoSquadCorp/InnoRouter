import Foundation
import OSLog

struct DeepLinkMatchMapping<Output: Sendable>: Sendable {
    let pattern: DeepLinkPattern
    private let handler: @Sendable (DeepLinkParameters) -> Output?

    init(
        _ pattern: String,
        handler: @escaping @Sendable (DeepLinkParameters) -> Output?
    ) {
        self.pattern = DeepLinkPattern(pattern)
        self.handler = handler
    }

    func match(_ parsed: DeepLinkParser.ParsedURL) -> Output? {
        guard let result = pattern.match(parsed) else { return nil }
        return handler(DeepLinkParameters(valuesByName: result.parameters))
    }
}

enum DeepLinkMatchEvaluation<Output: Sendable>: Sendable {
    case matched(Output)
    case unmatched
    case inputLimitExceeded(DeepLinkInputLimitViolation)
}

struct DeepLinkMatchEngine<Output: Sendable>: Sendable {
    private let mappings: [DeepLinkMatchMapping<Output>]
    private let inputLimits: DeepLinkInputLimits

    /// Structural authoring diagnostics for this engine's patterns.
    ///
    /// Computed on demand rather than stored. `DeepLinkPattern.makeDiagnostics`
    /// compares every pattern pair, so it is quadratic in catalog size, and
    /// `@Router` builds a matcher inside each generated `resolveDeepLink` call.
    /// Storing it therefore charged that quadratic pass to every deep-link
    /// resolution and then discarded the result, because generated matchers use
    /// `.disabled`. Measured on a 60-case catalog, one resolution spent ~620µs
    /// of its ~627µs here.
    ///
    /// `.disabled` suppresses *emission*, not availability: callers can still
    /// read diagnostics off a quiet matcher, which several contract tests rely
    /// on. Keeping the value computed preserves that without charging matchers
    /// that never read it. Recomputed per access, so bind it to a local when
    /// inspecting it repeatedly.
    var diagnostics: [DeepLinkMatcherDiagnostic] {
        DeepLinkPattern.makeDiagnostics(
            for: mappings.map(\.pattern)
        ).map(DeepLinkMatcherDiagnostic.init)
    }

    init(
        mappings: [DeepLinkMatchMapping<Output>],
        configuration: DeepLinkMatcherConfiguration
    ) {
        self.mappings = mappings
        self.inputLimits = configuration.inputLimits

        // Only materialize diagnostics when a mode will actually emit them.
        if configuration.diagnosticsMode != .disabled {
            DeepLinkMatcherDiagnostic.emit(diagnostics, configuration: configuration)
        }
    }

    init(
        validating mappings: [DeepLinkMatchMapping<Output>],
        logger: Logger?,
        inputLimits: DeepLinkInputLimits
    ) throws {
        let diagnostics = DeepLinkPattern.makeDiagnostics(
            for: mappings.map(\.pattern)
        ).map(DeepLinkMatcherDiagnostic.init)

        if !diagnostics.isEmpty {
            for diagnostic in diagnostics {
                logger?.error("\(diagnostic.message, privacy: .public)")
            }
            throw DeepLinkMatcherStrictError(diagnostics: diagnostics)
        }

        self.mappings = mappings
        self.inputLimits = inputLimits
    }

    func match(_ url: URL) -> Output? {
        guard case .matched(let output) = evaluate(url) else { return nil }
        return output
    }

    func match(_ urlString: String) -> Output? {
        guard let url = URL(string: urlString) else { return nil }
        return match(url)
    }

    func evaluate(
        _ url: URL,
        parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkMatchEvaluation<Output> {
        if let violation = inputLimits.urlLengthViolation(for: url) {
            return .inputLimitExceeded(violation)
        }
        return evaluate(parsed: parsed)
    }

    private func evaluate(_ url: URL) -> DeepLinkMatchEvaluation<Output> {
        if let violation = inputLimits.urlLengthViolation(for: url) {
            return .inputLimitExceeded(violation)
        }
        return evaluate(parsed: DeepLinkParser.parse(url))
    }

    private func evaluate(
        parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkMatchEvaluation<Output> {
        if let violation = inputLimits.parsedContentViolation(for: parsed) {
            return .inputLimitExceeded(violation)
        }

        for mapping in mappings {
            if let output = mapping.match(parsed) {
                return .matched(output)
            }
        }
        return .unmatched
    }
}
