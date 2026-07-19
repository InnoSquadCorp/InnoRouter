// MARK: - RouterDeepLinkReachability.swift
// InnoRouterMacrosPlugin - generated-handler reachability diagnostics.

import InnoRouterPatternSupport
import SwiftSyntaxMacros

func validateDeepLinkReachability(
    _ items: [RouterDeepLinkItem],
    context: some MacroExpansionContext
) -> Bool {
    let diagnostics = RoutePattern.makeDiagnostics(
        for: items.map { RoutePattern($0.pattern) }
    )
    guard !diagnostics.isEmpty else { return true }

    var duplicatePairs: [RouterDeepLinkDuplicatePair] = []
    var hardFailure = false
    let parsingSignatures = items.map(generatedHandlerParsingSignature(for:))

    for diagnostic in diagnostics {
        switch diagnostic {
        case .duplicatePattern(let pattern, let earlierIndex, let duplicateIndex):
            duplicatePairs.append(
                RouterDeepLinkDuplicatePair(
                    pattern: pattern,
                    earlierIndex: earlierIndex,
                    laterIndex: duplicateIndex
                )
            )
        case .wildcardShadowing(let pattern, let earlierIndex, let shadowed, let shadowedIndex):
            diagnoseUnreachableDeepLink(
                reason: "`\(shadowed)` is shadowed by wildcard `\(pattern)` at mapping \(earlierIndex + 1)",
                at: items[shadowedIndex].attribute,
                firstMapping: items[earlierIndex].attribute,
                context: context
            )
            hardFailure = true
        case .parameterShadowing(let pattern, let earlierIndex, let shadowed, let shadowedIndex):
            diagnoseUnreachableDeepLink(
                reason: "`\(shadowed)` is shadowed by parameter pattern `\(pattern)` at mapping \(earlierIndex + 1)",
                at: items[shadowedIndex].attribute,
                firstMapping: items[earlierIndex].attribute,
                context: context
            )
            hardFailure = true
        case .nonTerminalWildcard(let pattern, let invalidIndex):
            diagnoseDeepLink(
                .unreachablePattern(reason: "`\(pattern)` has a non-terminal wildcard"),
                at: items[min(invalidIndex, items.index(before: items.endIndex))].attribute,
                context: context
            )
            hardFailure = true
        case .invalidParameterName(let pattern, let invalidIndex, let name):
            diagnoseDeepLink(
                .unreachablePattern(reason: "`\(pattern)` contains invalid parameter `\(name)`"),
                at: items[min(invalidIndex, items.index(before: items.endIndex))].attribute,
                context: context
            )
            hardFailure = true
        @unknown default:
            hardFailure = true
        }
    }

    for laterIndex in Set(duplicatePairs.map(\.laterIndex)).sorted() {
        let pairs = duplicatePairs.filter { $0.laterIndex == laterIndex }
        guard let firstPair = pairs.first else { continue }

        if let unreachablePair = pairs.first(where: {
            guard let earlier = parsingSignatures[$0.earlierIndex],
                  let later = parsingSignatures[$0.laterIndex] else {
                return false
            }
            return earlier.acceptsEveryValueAccepted(by: later)
        }) {
            let earlier = parsingSignatures[unreachablePair.earlierIndex]
            let later = parsingSignatures[unreachablePair.laterIndex]
            let reason = earlier == later
                ? "`\(unreachablePair.pattern)` duplicates mapping \(unreachablePair.earlierIndex + 1)"
                : "`\(unreachablePair.pattern)` is fully handled by mapping "
                + "\(unreachablePair.earlierIndex + 1), whose generated typed conversion accepts "
                + "every value this mapping accepts"
            diagnoseUnreachableDeepLink(
                reason: reason,
                at: items[laterIndex].attribute,
                firstMapping: items[unreachablePair.earlierIndex].attribute,
                context: context
            )
            hardFailure = true
            continue
        }

        let precedingIndices = pairs.map(\.earlierIndex)
        diagnoseTypedFallbackDeepLink(
            reason: "`\(firstPair.pattern)` also matches \(precedingIndices.count) preceding "
                + "mapping\(precedingIndices.count == 1 ? "" : "s"); declaration order is used, "
                + "and this mapping is attempted only after all preceding typed conversions return nil",
            at: items[laterIndex].attribute,
            precedingMappings: precedingIndices.map { items[$0].attribute },
            context: context
        )
    }

    return !hardFailure
}

private struct RouterDeepLinkDuplicatePair {
    let pattern: String
    let earlierIndex: Int
    let laterIndex: Int
}

private struct RouterDeepLinkParsingSignature: Equatable {
    let pathTypes: [String]
    let queryTypes: [String: String]

    func acceptsEveryValueAccepted(by later: RouterDeepLinkParsingSignature) -> Bool {
        guard pathTypes.count == later.pathTypes.count else { return false }
        guard zip(pathTypes, later.pathTypes).allSatisfy({ earlier, later in
            earlier == "Swift.String" || earlier == later
        }) else {
            return false
        }

        return queryTypes.allSatisfy { label, earlier in
            earlier == "Swift.String" || later.queryTypes[label] == earlier
        }
    }
}

private func generatedHandlerParsingSignature(
    for item: RouterDeepLinkItem
) -> RouterDeepLinkParsingSignature? {
    guard case .success(let placeholders) = validateDeepLinkPattern(item.pattern) else {
        return nil
    }

    let parametersByLabel = Dictionary(
        uniqueKeysWithValues: item.parameters.map { ($0.label, $0) }
    )
    let pathTypes = placeholders.compactMap {
        parametersByLabel[$0].map {
            canonicalDeepLinkParameterTypeName($0.wrappedType)
        }
    }
    guard pathTypes.count == placeholders.count else { return nil }

    let placeholderSet = Set(placeholders)
    let queryTypes = Dictionary(uniqueKeysWithValues: item.parameters
        .filter { !placeholderSet.contains($0.label) }
        .map {
            ($0.label, canonicalDeepLinkParameterTypeName($0.wrappedType))
        })

    return RouterDeepLinkParsingSignature(
        pathTypes: pathTypes,
        queryTypes: queryTypes
    )
}

private let swiftDeepLinkParameterTypeNames: Set<String> = [
    "String", "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float", "Bool",
]

private func canonicalDeepLinkParameterTypeName(_ typeName: String) -> String {
    if swiftDeepLinkParameterTypeNames.contains(typeName) {
        return "Swift.\(typeName)"
    }
    if typeName.hasPrefix("Swift.") {
        let unqualified = String(typeName.dropFirst("Swift.".count))
        if swiftDeepLinkParameterTypeNames.contains(unqualified) {
            return "Swift.\(unqualified)"
        }
    }
    if typeName == "UUID" || typeName == "Foundation.UUID" {
        return "Foundation.UUID"
    }
    return typeName
}
