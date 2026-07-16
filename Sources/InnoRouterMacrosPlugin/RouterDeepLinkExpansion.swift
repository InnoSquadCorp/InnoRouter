// MARK: - RouterDeepLinkExpansion.swift
// InnoRouterMacrosPlugin - @Router deep-link analysis and generation
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import InnoRouterDeepLink
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

enum RouterDeepLinkExpansion {
    case none
    case invalid
    case valid(RouterDeepLinkSpecification)
}

struct RouterDeepLinkSpecification {
    let schemes: [String]
    let hosts: [String]
    let items: [RouterDeepLinkItem]
    let directlyConformsToDeepLinkRoute: Bool
}

struct RouterDeepLinkItem {
    let caseName: String
    let pattern: String
    let parameters: [RouterDeepLinkParameter]
    let attribute: AttributeSyntax
}

struct RouterDeepLinkParameter {
    let label: String
    let emittedLabel: String
    let type: String
    let wrappedType: String
    let isOptional: Bool
}

func analyzeRouterDeepLinks(
    routerAttribute: AttributeSyntax,
    in enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) -> RouterDeepLinkExpansion {
    let directCases = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    let conditionalCases = enumDecl.memberBlock.members.flatMap { member in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else {
            return [EnumCaseDeclSyntax]()
        }
        return deepLinkCasesInsideConditional(conditional)
    }
    let markedDirectCases = directCases.filter { !deepLinkAttributes(on: $0).isEmpty }
    let conditionallyAttributedDirectCases = directCases.filter {
        conditionalDeepLinkAttribute(on: $0) != nil
    }
    let markedConditionalCases = conditionalCases.filter { containsDeepLinkAttribute(on: $0) }

    let originResult = parseDeepLinkOrigin(from: routerAttribute)
    switch originResult {
    case .failure(let reason):
        diagnoseDeepLink(.invalidRouterArguments(reason: reason), at: routerAttribute, context: context)
        return .invalid
    case .success(let origin):
        if let conditionalCase = markedConditionalCases.first {
            diagnoseDeepLink(.conditionalCase, at: conditionalCase, context: context)
            return .invalid
        }
        if let conditionalAttribute = conditionallyAttributedDirectCases
            .lazy
            .compactMap(conditionalDeepLinkAttribute(on:))
            .first {
            diagnoseDeepLink(.conditionalCase, at: conditionalAttribute, context: context)
            return .invalid
        }
        guard !markedDirectCases.isEmpty || !markedConditionalCases.isEmpty else {
            if origin.hasValues {
                diagnoseDeepLink(.unusedAllowlist, at: routerAttribute, context: context)
            }
            return .none
        }

        guard origin.schemes.isEmpty == false, origin.hosts.isEmpty == false else {
            diagnoseDeepLink(.missingAllowlist, at: routerAttribute, context: context)
            return .invalid
        }
        var items: [RouterDeepLinkItem] = []
        for caseDecl in markedDirectCases {
            guard let item = analyzeDeepLinkCase(caseDecl, context: context) else {
                return .invalid
            }
            items.append(item)
        }

        let patterns = items.map { DeepLinkPattern($0.pattern) }
        let orderedItems = DeepLinkPattern
            .specificityOrderedIndices(for: patterns)
            .map { items[$0] }

        guard validateDeepLinkReachability(orderedItems, context: context) else {
            return .invalid
        }
        if let conflictingResolver = conflictingDeepLinkResolver(in: enumDecl) {
            diagnoseDeepLink(.conflictingResolver, at: conflictingResolver, context: context)
            return .invalid
        }

        let directlyConforms = directlyConforms(enumDecl, to: "DeepLinkRoute")
        if directlyConforms, let inheritanceClause = enumDecl.inheritanceClause {
            diagnoseDeepLink(.redundantConformance, at: inheritanceClause, context: context)
        }

        return .valid(
            RouterDeepLinkSpecification(
                schemes: origin.schemes,
                hosts: origin.hosts,
                items: orderedItems,
                directlyConformsToDeepLinkRoute: directlyConforms
            )
        )
    }
}

func renderRouterDeepLinkMembers(
    from specification: RouterDeepLinkSpecification,
    access: String
) -> String {
    let mappings = specification.items
        .map { indentContinuationLines(renderDeepLinkMapping($0), by: 8) }
        .joined(separator: "\n        ")
    let schemes = specification.schemes.map(swiftStringLiteral).joined(separator: ", ")
    let hosts = specification.hosts.map(swiftStringLiteral).joined(separator: ", ")

    return """
    \(access) static func resolveDeepLink(_ url: Foundation.URL) -> Self? {
        guard url.user == nil, url.password == nil, url.port == nil else {
            return nil
        }
        let matcher = InnoRouterDeepLink.DeepLinkMatcher<Self>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            \(mappings)
        }
        let pipeline = InnoRouterDeepLink.DeepLinkPipeline<Self>(
            allowedSchemes: [\(schemes)],
            allowedHosts: [\(hosts)],
            matcher: matcher
        )
        guard case .plan(let plan) = pipeline.decide(for: url),
              plan.commands.count == 1,
              case .push(let route) = plan.commands[0] else {
            return nil
        }
        return route
    }
    """
}

private func analyzeDeepLinkCase(
    _ caseDecl: EnumCaseDeclSyntax,
    context: some MacroExpansionContext
) -> RouterDeepLinkItem? {
    let attributes = deepLinkAttributes(on: caseDecl)
    guard attributes.count == 1, let attribute = attributes.first else {
        diagnoseDeepLink(.duplicateMarker, at: attributes[1], context: context)
        return nil
    }
    guard caseDecl.elements.count == 1, let element = caseDecl.elements.first else {
        diagnoseDeepLink(.multipleCasesPerDeclaration, at: caseDecl, context: context)
        return nil
    }
    guard !hasDeepLinkAvailabilityAttribute(caseDecl) else {
        diagnoseDeepLink(
            .unavailableCase(caseName: element.name.text),
            at: caseDecl,
            context: context
        )
        return nil
    }
    guard let pattern = deepLinkPatternLiteral(attribute) else {
        diagnoseDeepLink(
            .invalidPattern(reason: "provide one nonempty plain string literal"),
            at: attribute,
            context: context
        )
        return nil
    }
    let validation = validateDeepLinkPattern(pattern)
    guard case .success(let placeholders) = validation else {
        if case .failure(let reason) = validation {
            diagnoseDeepLink(.invalidPattern(reason: reason), at: attribute, context: context)
        }
        return nil
    }
    guard let parameters = analyzeDeepLinkParameters(element, context: context) else {
        return nil
    }
    guard validatePlaceholderPayload(
        placeholders: placeholders,
        parameters: parameters,
        at: attribute,
        context: context
    ) else {
        return nil
    }

    return RouterDeepLinkItem(
        caseName: escapedIdentifier(element.name),
        pattern: pattern,
        parameters: parameters,
        attribute: attribute
    )
}

private enum DeepLinkPatternValidation {
    case success([String])
    case failure(String)
}

private func validateDeepLinkPattern(_ pattern: String) -> DeepLinkPatternValidation {
    guard pattern.first == "/" else {
        return .failure("start the path with `/`")
    }
    guard !pattern.contains("?"), !pattern.contains("#") else {
        return .failure("query and fragment syntax are not part of a path pattern")
    }
    guard pattern == "/" || !pattern.hasSuffix("/") else {
        return .failure("omit the trailing slash")
    }
    guard !pattern.contains("//") else {
        return .failure("empty path segments are not allowed")
    }

    let body = pattern.dropFirst()
    let segments = body.isEmpty ? [] : body.split(separator: "/").map(String.init)
    var placeholders: [String] = []
    for (index, segment) in segments.enumerated() {
        if segment == "*" {
            guard index == segments.index(before: segments.endIndex) else {
                return .failure("`*` must be the terminal segment")
            }
            continue
        }
        if segment.hasPrefix(":") {
            let name = String(segment.dropFirst())
            guard isASCIIIdentifier(name) else {
                return .failure("`:parameter` names must be ASCII Swift identifiers")
            }
            guard !placeholders.contains(name) else {
                return .failure("placeholder `:\(name)` is repeated")
            }
            placeholders.append(name)
            continue
        }
        guard segment.unicodeScalars.allSatisfy(isURLPathLiteralScalar) else {
            return .failure("literal segments may contain only URL-unreserved ASCII characters")
        }
    }
    return .success(placeholders)
}

private func analyzeDeepLinkParameters(
    _ element: EnumCaseElementSyntax,
    context: some MacroExpansionContext
) -> [RouterDeepLinkParameter]? {
    guard let syntaxParameters = element.parameterClause?.parameters else { return [] }
    var parameters: [RouterDeepLinkParameter] = []
    var labels: Set<String> = []
    for parameter in syntaxParameters {
        guard let firstName = parameter.firstName, firstName.text != "_" else {
            diagnoseDeepLink(
                .invalidAssociatedValue(reason: "every value needs an explicit external label"),
                at: parameter,
                context: context
            )
            return nil
        }
        let label = firstName.text
        guard labels.insert(label).inserted else {
            diagnoseDeepLink(
                .invalidAssociatedValue(reason: "label `\(label)` is duplicated"),
                at: parameter,
                context: context
            )
            return nil
        }
        guard let type = deepLinkParameterType(parameter.type) else {
            diagnoseDeepLink(
                .invalidAssociatedValue(
                    reason: "`\(parameter.type.trimmedDescription)` must be a nominal DeepLinkParameterValue or Optional of one"
                ),
                at: parameter,
                context: context
            )
            return nil
        }
        parameters.append(
            RouterDeepLinkParameter(
                label: label,
                emittedLabel: escapedIdentifier(firstName),
                type: parameter.type.trimmedDescription,
                wrappedType: type.wrappedType,
                isOptional: type.isOptional
            )
        )
    }
    return parameters
}

private func validatePlaceholderPayload(
    placeholders: [String],
    parameters: [RouterDeepLinkParameter],
    at node: AttributeSyntax,
    context: some MacroExpansionContext
) -> Bool {
    let labels = Set(parameters.map(\.label))
    if let missing = placeholders.first(where: { !labels.contains($0) }) {
        diagnoseDeepLink(
            .patternPayloadMismatch(reason: "placeholder `:\(missing)` has no case value with label `\(missing)`"),
            at: node,
            context: context
        )
        return false
    }
    let placeholderSet = Set(placeholders)
    if let requiredQueryOnly = parameters.first(where: {
        !$0.isOptional && !placeholderSet.contains($0.label)
    }) {
        diagnoseDeepLink(
            .patternPayloadMismatch(
                reason: "required value `\(requiredQueryOnly.label)` must appear as a path placeholder"
            ),
            at: node,
            context: context
        )
        return false
    }
    return true
}

private func validateDeepLinkReachability(
    _ items: [RouterDeepLinkItem],
    context: some MacroExpansionContext
) -> Bool {
    let diagnostics = DeepLinkPattern.makeDiagnostics(
        for: items.map { DeepLinkPattern($0.pattern) }
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
                : "`\(unreachablePair.pattern)` is fully handled by mapping " +
                "\(unreachablePair.earlierIndex + 1), whose generated typed conversion accepts " +
                "every value this mapping accepts"
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
            reason: "`\(firstPair.pattern)` also matches \(precedingIndices.count) preceding " +
                "mapping\(precedingIndices.count == 1 ? "" : "s"); declaration order is used, " +
                "and this mapping is attempted only after all preceding typed conversions return nil",
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

    func acceptsEveryValueAccepted(
        by later: RouterDeepLinkParsingSignature
    ) -> Bool {
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
    "String",
    "Int",
    "Int8",
    "Int16",
    "Int32",
    "Int64",
    "UInt",
    "UInt8",
    "UInt16",
    "UInt32",
    "UInt64",
    "Double",
    "Float",
    "Bool",
]

/// Macro expansion has syntax but no type-resolution context. Canonicalize the
/// standard spellings that InnoRouter itself makes `DeepLinkParameterValue` so
/// reachability does not change when a caller writes `Int` instead of
/// `Swift.Int`. Preserve every other nominal type verbatim because its parser
/// may have custom acceptance rules.
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

private struct DeepLinkParameterType {
    let wrappedType: String
    let isOptional: Bool
}

private func deepLinkParameterType(_ type: TypeSyntax) -> DeepLinkParameterType? {
    if let optional = type.as(OptionalTypeSyntax.self),
       isSupportedDeepLinkNominalType(optional.wrappedType) {
        return DeepLinkParameterType(
            wrappedType: optional.wrappedType.trimmedDescription,
            isOptional: true
        )
    }
    if let wrapped = explicitOptionalWrappedType(type),
       isSupportedDeepLinkNominalType(wrapped) {
        return DeepLinkParameterType(
            wrappedType: wrapped.trimmedDescription,
            isOptional: true
        )
    }
    guard isSupportedDeepLinkNominalType(type) else { return nil }
    return DeepLinkParameterType(wrappedType: type.trimmedDescription, isOptional: false)
}

private func explicitOptionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
    if let identifier = type.as(IdentifierTypeSyntax.self),
       identifier.name.text == "Optional",
       let arguments = identifier.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return wrappedType
    }
    if let member = type.as(MemberTypeSyntax.self),
       member.name.text == "Optional",
       member.baseType.trimmedDescription == "Swift",
       let arguments = member.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return wrappedType
    }
    return nil
}

private func isSupportedDeepLinkNominalType(_ type: TypeSyntax) -> Bool {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return identifier.genericArgumentClause == nil
    }
    if let member = type.as(MemberTypeSyntax.self) {
        return member.genericArgumentClause == nil && isSupportedDeepLinkNominalType(member.baseType)
    }
    return false
}
