import Foundation

/// A validated, canonical URL origin used when rendering typed deep links.
public struct DeepLinkOrigin: Sendable, Hashable {
    /// The lowercase RFC-compatible URL scheme.
    public let scheme: String

    /// The lowercase ASCII DNS, IPv4, or `localhost` host.
    public let host: String

    /// Creates an origin, returning `nil` for malformed schemes or hosts.
    public init?(scheme: String, host: String) {
        let normalizedScheme = scheme.lowercased()
        let normalizedHost = host.lowercased()
        guard Self.isValidScheme(normalizedScheme),
              Self.isValidHost(normalizedHost) else {
            return nil
        }
        self.scheme = normalizedScheme
        self.host = normalizedHost
    }

    private static func isValidScheme(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              isASCIILetter(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy { scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) || "+-.".unicodeScalars.contains(scalar)
        }
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253,
              value.unicodeScalars.allSatisfy(\.isASCII) else {
            return false
        }
        if value == "localhost" { return true }
        if value.unicodeScalars.allSatisfy({ isASCIIDigit($0) || $0 == "." }) {
            let octets = value.split(separator: ".", omittingEmptySubsequences: false)
            return octets.count == 4 && octets.allSatisfy { octet in
                !octet.isEmpty && octet.count <= 3 && Int(octet).map { (0 ... 255).contains($0) } == true
            }
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  let first = label.unicodeScalars.first,
                  let last = label.unicodeScalars.last,
                  isASCIIAlphaNumeric(first), isASCIIAlphaNumeric(last) else {
                return false
            }
            return label.unicodeScalars.allSatisfy { scalar in
                isASCIIAlphaNumeric(scalar) || scalar == "-"
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || isASCIIDigit(scalar)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48 ... 57).contains(scalar.value)
    }
}

/// One named value used by ``DeepLinkURLBuilder``.
public struct DeepLinkURLParameter: Sendable, Hashable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }

    /// Creates a rendered parameter from any supported typed value.
    public init<Value: DeepLinkParameterValue>(name: String, value: Value?) {
        self.name = name
        self.value = value?.deepLinkParameterString
    }
}

/// Builds a canonical URL from a validated origin and route pattern.
///
/// Path placeholders consume parameters with the same name. Remaining
/// non-`nil` parameters become query items in declaration order. A terminal
/// wildcard renders its literal prefix because wildcard input is not captured
/// by the route declaration.
public enum DeepLinkURLBuilder {
    public static func makeURL(
        origin: DeepLinkOrigin,
        pattern: String,
        parameters: [DeepLinkURLParameter] = []
    ) -> URL? {
        let valuesByName = Dictionary(
            parameters.map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        var pathParameterNames: Set<String> = []
        var percentEncodedSegments: [String] = []

        for segment in pattern.split(separator: "/") {
            let value = String(segment)
            if value == "*" {
                break
            }
            if value.hasPrefix(":"), value.count > 1 {
                let name = String(value.dropFirst())
                pathParameterNames.insert(name)
                guard let parameter = valuesByName[name] ?? nil,
                      let encoded = percentEncodePathSegment(parameter) else {
                    return nil
                }
                percentEncodedSegments.append(encoded)
            } else {
                guard let encoded = percentEncodePathSegment(value) else {
                    return nil
                }
                percentEncodedSegments.append(encoded)
            }
        }

        var components = URLComponents()
        components.scheme = origin.scheme
        components.host = origin.host
        components.percentEncodedPath = "/" + percentEncodedSegments.joined(separator: "/")
        components.queryItems = parameters.compactMap { parameter in
            guard !pathParameterNames.contains(parameter.name),
                  let value = parameter.value else {
                return nil
            }
            return URLQueryItem(name: parameter.name, value: value)
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.url
    }

    private static func percentEncodePathSegment(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: .deepLinkPathSegmentAllowed)
    }
}

private extension CharacterSet {
    static let deepLinkPathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
