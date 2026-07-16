import SwiftSyntax

struct RouterDeepLinkOrigin {
    let schemes: [String]
    let hosts: [String]

    var hasValues: Bool { !schemes.isEmpty || !hosts.isEmpty }
}

enum RouterDeepLinkOriginResult {
    case success(RouterDeepLinkOrigin)
    case failure(String)
}

func parseDeepLinkOrigin(from attribute: AttributeSyntax) -> RouterDeepLinkOriginResult {
    guard case .argumentList(let arguments) = attribute.arguments else {
        return .success(RouterDeepLinkOrigin(schemes: [], hosts: []))
    }

    var schemes: [String] = []
    var hosts: [String] = []
    var seenLabels: Set<String> = []
    for argument in arguments {
        guard let label = argument.label?.text,
              label == "deepLinkSchemes" || label == "deepLinkHosts" else {
            return .failure("use only the `deepLinkSchemes:` and `deepLinkHosts:` labels")
        }
        guard seenLabels.insert(label).inserted else {
            return .failure("`\(label)` may only be provided once")
        }
        guard let values = plainStringArray(argument.expression) else {
            return .failure("`\(label)` must be an array of plain string literals")
        }
        if label == "deepLinkSchemes" {
            schemes = values
        } else {
            hosts = values
        }
    }

    let normalizedSchemes = schemes.map { $0.lowercased() }
    let normalizedHosts = hosts.map { $0.lowercased() }
    guard Set(normalizedSchemes).count == normalizedSchemes.count else {
        return .failure("deepLinkSchemes contains a duplicate after case normalization")
    }
    guard Set(normalizedHosts).count == normalizedHosts.count else {
        return .failure("deepLinkHosts contains a duplicate after case normalization")
    }
    guard let invalidScheme = normalizedSchemes.first(where: { !isValidDeepLinkScheme($0) }) else {
        guard let invalidHost = normalizedHosts.first(where: { !isValidDeepLinkHost($0) }) else {
            return .success(
                RouterDeepLinkOrigin(schemes: normalizedSchemes, hosts: normalizedHosts)
            )
        }
        return .failure("`\(invalidHost)` is not an exact ASCII DNS, IPv4, or localhost host")
    }
    return .failure("`\(invalidScheme)` is not an RFC-compatible URL scheme")
}
