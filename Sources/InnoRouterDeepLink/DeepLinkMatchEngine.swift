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
    let diagnostics: [DeepLinkMatcherDiagnostic]

    init(
        mappings: [DeepLinkMatchMapping<Output>],
        configuration: DeepLinkMatcherConfiguration
    ) {
        let diagnostics = DeepLinkPattern.makeDiagnostics(
            for: mappings.map(\.pattern)
        ).map(DeepLinkMatcherDiagnostic.init)

        self.mappings = mappings
        self.inputLimits = configuration.inputLimits
        self.diagnostics = diagnostics

        DeepLinkMatcherDiagnostic.emit(diagnostics, configuration: configuration)
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
        self.diagnostics = diagnostics
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
