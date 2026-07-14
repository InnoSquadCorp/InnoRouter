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
        )

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
        )

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
        guard inputLimits.urlLengthViolation(for: url) == nil else { return nil }
        let parsed = DeepLinkParser.parse(url)
        guard inputLimits.parsedContentViolation(for: parsed) == nil else { return nil }
        return match(parsed: parsed)
    }

    func match(_ urlString: String) -> Output? {
        guard let url = URL(string: urlString) else { return nil }
        return match(url)
    }

    func match(parsed: DeepLinkParser.ParsedURL) -> Output? {
        for mapping in mappings {
            if let output = mapping.match(parsed) {
                return output
            }
        }
        return nil
    }

    func inputLimitViolation(
        for url: URL,
        parsed: DeepLinkParser.ParsedURL
    ) -> DeepLinkInputLimitViolation? {
        inputLimits.urlLengthViolation(for: url)
            ?? inputLimits.parsedContentViolation(for: parsed)
    }
}
