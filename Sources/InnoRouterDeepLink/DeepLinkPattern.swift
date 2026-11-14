import Foundation

struct DeepLinkParser: Sendable {
    struct ParsedURL: Sendable, Equatable {
        let scheme: String?
        let host: String?
        let path: [String]
        let queryItems: [String: [String]]
        /// Indices in `path` whose segment carries percent-encoding that does
        /// not decode to UTF-8. Those entries hold the segment as written.
        ///
        /// A pattern never matches when one of its literal or parameter
        /// positions falls on such a segment: comparing or delivering the raw
        /// `%FF` would not fail closed. A segment that only a trailing
        /// wildcard swallows is never compared or delivered, so it does not
        /// affect the match.
        let malformedPathIndices: Set<Int>
        /// Positions in `queryItems[name]` whose value (or whose name, filed
        /// under the empty name) does not percent-decode to UTF-8.
        let undecodableQueryValues: [String: Set<Int>]

        /// Positions of those values in a match's merged parameters. Path
        /// captures come first under each name, so query positions shift by
        /// the number of captures.
        func undecodableValueIndices(inMerged merged: [String: [String]]) -> [String: Set<Int>] {
            var result: [String: Set<Int>] = [:]
            for (name, indices) in undecodableQueryValues {
                let offset = (merged[name]?.count ?? 0) - (queryItems[name]?.count ?? 0)
                result[name] = Set(indices.map { $0 + offset })
            }
            return result
        }

        init(url: URL) {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            self.scheme = components?.scheme
            self.host = components?.host
            // Split the encoded path before decoding each segment exactly
            // once. Splitting a decoded path would turn `%2F` into a new
            // routing boundary, while decoding `URL.pathComponents` again
            // would turn `%252F` into `/` instead of the literal `%2F`.
            let encodedPath = components?.percentEncodedPath ?? url.path(percentEncoded: true)
            var malformedPathIndices: Set<Int> = []
            self.path = encodedPath
                .split(separator: "/")
                .enumerated()
                .map { index, encodedComponent in
                    let component = String(encodedComponent)
                    guard let decoded = component.removingPercentEncoding else {
                        malformedPathIndices.insert(index)
                        return component
                    }
                    return decoded
                }
            self.malformedPathIndices = malformedPathIndices

            // Decoded from the encoded items alone. `queryItems` reports an
            // undecodable value as missing, which cannot be told apart from an
            // item written without a value. Such a value keeps its place as
            // the empty string, exactly where 7.0 put it, so names, counts,
            // limits, and positions are unchanged; it is also recorded, because
            // no typed read may accept it.
            var parsedQueryItems: [String: [String]] = [:]
            var undecodableQueryValues: [String: Set<Int>] = [:]
            for encoded in components?.percentEncodedQueryItems ?? [] {
                let decodedName = encoded.name.removingPercentEncoding
                let decodedValue = encoded.value.map { $0.removingPercentEncoding }
                let name = decodedName ?? ""
                var isUndecodable = decodedName == nil
                if case .some(nil) = decodedValue { isUndecodable = true }
                if isUndecodable {
                    undecodableQueryValues[name, default: []].insert(parsedQueryItems[name]?.count ?? 0)
                }
                parsedQueryItems[name, default: []].append((decodedValue ?? nil) ?? "")
            }
            self.queryItems = parsedQueryItems
            self.undecodableQueryValues = undecodableQueryValues

            // URL fragments are deliberately not parsed: the route pattern
            // grammar matches scheme, host, path, and query only, so a
            // stored fragment would imply matching support that does not
            // exist.
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
        let examined = examinedPathPartCount
        guard parsed.malformedPathIndices.allSatisfy({ $0 >= examined }),
              let result = match(pathParts: parsed.path) else { return nil }
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
