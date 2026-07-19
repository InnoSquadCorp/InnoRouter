import Foundation

enum DeepLinkAdmissionOutcome<Output: Sendable>: Sendable {
    case matched(Output)
    case unhandled
    case rejected(DeepLinkRejectionReason)
}

private enum DeepLinkAdmissionSource<Output: Sendable>: Sendable {
    case matcher(DeepLinkMatcher<Output>)
    case customResolver(@Sendable (URL) -> Output?)
}

/// Shared URL admission and resolution path for push and flow pipelines.
///
/// Pipeline limits intentionally run before scheme and host validation. Matcher
/// limits run after those validations so both public pipelines preserve the same
/// rejection precedence while sharing one parsed URL for matching.
struct DeepLinkAdmission<Output: Sendable>: Sendable {
    private let allowedSchemes: Set<String>?
    private let allowedHosts: Set<String>?
    private let source: DeepLinkAdmissionSource<Output>
    private let inputLimits: DeepLinkInputLimits

    init(
        originPolicy: DeepLinkOriginPolicy,
        matcher: DeepLinkMatcher<Output>,
        inputLimits: DeepLinkInputLimits
    ) {
        let allowlists = originPolicy.allowlists
        self.init(
            allowedSchemes: allowlists.schemes,
            allowedHosts: allowlists.hosts,
            matcher: matcher,
            inputLimits: inputLimits
        )
    }

    init(
        originPolicy: DeepLinkOriginPolicy,
        customResolver: @escaping @Sendable (URL) -> Output?,
        inputLimits: DeepLinkInputLimits
    ) {
        let allowlists = originPolicy.allowlists
        self.init(
            allowedSchemes: allowlists.schemes,
            allowedHosts: allowlists.hosts,
            customResolver: customResolver,
            inputLimits: inputLimits
        )
    }

    init(
        allowedSchemes: Set<String>?,
        allowedHosts: Set<String>?,
        matcher: DeepLinkMatcher<Output>,
        inputLimits: DeepLinkInputLimits
    ) {
        self.allowedSchemes = allowedSchemes?.lowercased
        self.allowedHosts = allowedHosts?.lowercased
        self.source = .matcher(matcher)
        self.inputLimits = inputLimits
    }

    init(
        allowedSchemes: Set<String>?,
        allowedHosts: Set<String>?,
        customResolver: @escaping @Sendable (URL) -> Output?,
        inputLimits: DeepLinkInputLimits
    ) {
        self.allowedSchemes = allowedSchemes?.lowercased
        self.allowedHosts = allowedHosts?.lowercased
        self.source = .customResolver(customResolver)
        self.inputLimits = inputLimits
    }

    func evaluate(_ url: URL) -> DeepLinkAdmissionOutcome<Output> {
        if let violation = inputLimits.urlLengthViolation(for: url) {
            return .rejected(.inputLimitExceeded(violation))
        }

        let parsed = DeepLinkParser.parse(url)

        if let violation = inputLimits.parsedContentViolation(for: parsed) {
            return .rejected(.inputLimitExceeded(violation))
        }

        if let allowedSchemes {
            guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
                return .rejected(.schemeNotAllowed(actualScheme: url.scheme))
            }
        }

        if let allowedHosts {
            guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
                return .rejected(.hostNotAllowed(actualHost: url.host))
            }
        }

        switch source {
        case .matcher(let matcher):
            switch matcher.evaluate(url, parsed: parsed) {
            case .matched(let output):
                return .matched(output)
            case .unmatched:
                return .unhandled
            case .inputLimitExceeded(let violation):
                return .rejected(.inputLimitExceeded(violation))
            }

        case .customResolver(let resolve):
            guard let output = resolve(url) else { return .unhandled }
            return .matched(output)
        }
    }
}

private extension DeepLinkOriginPolicy {
    var allowlists: (schemes: Set<String>?, hosts: Set<String>?) {
        switch self {
        case .allowlisted(let schemes, let hosts):
            return (schemes, hosts)
        case .trustedInProcess:
            return (nil, nil)
        }
    }
}

private extension Set where Element == String {
    var lowercased: Set<String> {
        Set(map { $0.lowercased() })
    }
}
