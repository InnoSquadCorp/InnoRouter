import SwiftSyntax

struct RouterDeepLinkOrigin {
    let schemes: [String]
    let hosts: [String]
    let generatesInspectorCatalog: Bool

    var hasValues: Bool { !schemes.isEmpty || !hosts.isEmpty }
}

enum RouterDeepLinkOriginResult {
    case success(RouterDeepLinkOrigin)
    case failure(String)
}

func parseDeepLinkOrigin(from attribute: AttributeSyntax) -> RouterDeepLinkOriginResult {
    guard case .argumentList(let arguments) = attribute.arguments else {
        return .success(RouterDeepLinkOrigin(
            schemes: [],
            hosts: [],
            generatesInspectorCatalog: false
        ))
    }

    var schemes: [String] = []
    var hosts: [String] = []
    var generatesInspectorCatalog = false
    var seenLabels: Set<String> = []
    for argument in arguments {
        guard let label = argument.label?.text,
              label == "deepLinkSchemes"
                || label == "deepLinkHosts"
                || label == "inspectorCatalog" else {
            return .failure("use only the `deepLinkSchemes:`, `deepLinkHosts:`, and `inspectorCatalog:` labels")
        }
        guard seenLabels.insert(label).inserted else {
            return .failure("`\(label)` may only be provided once")
        }
        if label == "inspectorCatalog" {
            guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
                return .failure("`inspectorCatalog` must be a Boolean literal")
            }
            generatesInspectorCatalog = literal.literal.tokenKind == .keyword(.true)
        } else if label == "deepLinkSchemes" {
            guard let values = plainStringArray(argument.expression) else {
                return .failure("`\(label)` must be an array of plain string literals")
            }
            schemes = values
        } else {
            guard let values = plainStringArray(argument.expression) else {
                return .failure("`\(label)` must be an array of plain string literals")
            }
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
                RouterDeepLinkOrigin(
                    schemes: normalizedSchemes,
                    hosts: normalizedHosts,
                    generatesInspectorCatalog: generatesInspectorCatalog
                )
            )
        }
        return .failure("`\(invalidHost)` is not an exact ASCII DNS, IPv4, or localhost host")
    }
    return .failure("`\(invalidScheme)` is not an RFC-compatible URL scheme")
}
