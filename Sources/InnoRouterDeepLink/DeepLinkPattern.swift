import Foundation

import InnoRouterPatternSupport

struct DeepLinkParser: Sendable {
    struct ParsedURL: Sendable, Equatable {
        let scheme: String?
        let host: String?
        let path: [String]
        let queryItems: [String: [String]]
        let fragment: String?

        init(url: URL) {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            self.scheme = components?.scheme
            self.host = components?.host
            // Split the encoded path before decoding each segment exactly
            // once. Splitting a decoded path would turn `%2F` into a new
            // routing boundary, while decoding `URL.pathComponents` again
            // would turn `%252F` into `/` instead of the literal `%2F`.
            let encodedPath = components?.percentEncodedPath ?? url.path(percentEncoded: true)
            self.path = encodedPath
                .split(separator: "/")
                .map { encodedComponent in
                    let component = String(encodedComponent)
                    return component.removingPercentEncoding ?? component
                }

            var parsedQueryItems: [String: [String]] = [:]
            for item in components?.queryItems ?? [] {
                parsedQueryItems[item.name, default: []].append(item.value ?? "")
            }
            self.queryItems = parsedQueryItems

            self.fragment = components?.fragment
        }

        var firstQueryItems: [String: String] {
            queryItems.compactMapValues { $0.first }
        }
    }

    static func parse(_ urlString: String) -> ParsedURL? {
        guard let url = URL(string: urlString) else { return nil }
        return ParsedURL(url: url)
    }

    static func parse(_ url: URL) -> ParsedURL {
        ParsedURL(url: url)
    }
}

package typealias DeepLinkPattern = RoutePattern

extension DeepLinkPattern {
    func match(_ parsed: DeepLinkParser.ParsedURL) -> MatchResult? {
        guard let result = match(pathParts: parsed.path) else { return nil }
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
}
