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

private struct RouterDeepLinkOrigin {
    let schemes: [String]
    let hosts: [String]

    var hasValues: Bool { !schemes.isEmpty || !hosts.isEmpty }
}

private enum RouterDeepLinkOriginResult {
    case success(RouterDeepLinkOrigin)
    case failure(String)
}

private func parseDeepLinkOrigin(from attribute: AttributeSyntax) -> RouterDeepLinkOriginResult {
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
    guard let diagnostic = diagnostics.first else { return true }

    let index: Int
    let precedingIndex: Int?
    let reason: String
    switch diagnostic {
    case .duplicatePattern(let pattern, let earlierIndex, let duplicateIndex):
        index = duplicateIndex
        precedingIndex = earlierIndex
        reason = "`\(pattern)` duplicates mapping \(earlierIndex + 1)"
    case .wildcardShadowing(let pattern, let earlierIndex, let shadowed, let shadowedIndex):
        index = shadowedIndex
        precedingIndex = earlierIndex
        reason = "`\(shadowed)` is shadowed by wildcard `\(pattern)` at mapping \(earlierIndex + 1)"
    case .parameterShadowing(let pattern, let earlierIndex, let shadowed, let shadowedIndex):
        index = shadowedIndex
        precedingIndex = earlierIndex
        reason = "`\(shadowed)` is shadowed by parameter pattern `\(pattern)` at mapping \(earlierIndex + 1)"
    case .nonTerminalWildcard(let pattern, let invalidIndex):
        index = min(invalidIndex, items.index(before: items.endIndex))
        precedingIndex = nil
        reason = "`\(pattern)` has a non-terminal wildcard"
    case .invalidParameterName(let pattern, let invalidIndex, let name):
        index = min(invalidIndex, items.index(before: items.endIndex))
        precedingIndex = nil
        reason = "`\(pattern)` contains invalid parameter `\(name)`"
    @unknown default:
        return false
    }
    if let precedingIndex {
        diagnoseUnreachableDeepLink(
            reason: reason,
            at: items[index].attribute,
            firstMapping: items[precedingIndex].attribute,
            context: context
        )
    } else {
        diagnoseDeepLink(
            .unreachablePattern(reason: reason),
            at: items[index].attribute,
            context: context
        )
    }
    return false
}

private func renderDeepLinkMapping(_ item: RouterDeepLinkItem) -> String {
    var statements = item.parameters.enumerated().map { index, parameter in
        renderDeepLinkBinding(index: index, parameter: parameter)
    }
    let arguments = item.parameters.enumerated().map { index, parameter in
        "\(parameter.emittedLabel): deepLinkValue\(index)"
    }.joined(separator: ", ")
    let constructor = arguments.isEmpty
        ? ".\(item.caseName)"
        : ".\(item.caseName)(\(arguments))"
    statements.append("return \(constructor)")

    return "InnoRouterDeepLink.DeepLinkMapping(\(swiftStringLiteral(item.pattern))) { parameters in\n"
        + indentEveryLine(statements.joined(separator: "\n"), by: 4)
        + "\n}"
}

private func renderDeepLinkBinding(
    index: Int,
    parameter: RouterDeepLinkParameter
) -> String {
    let name = "deepLinkValue\(index)"
    let key = swiftStringLiteral(parameter.label)
    if parameter.isOptional {
        return """
        let \(name): \(parameter.type)
        if parameters.firstValue(forName: \(key)) != nil {
            guard let parsedDeepLinkValue\(index) = parameters.firstValue(
                forName: \(key),
                as: \(parameter.wrappedType).self
            ) else {
                return nil
            }
            \(name) = parsedDeepLinkValue\(index)
        } else {
            \(name) = nil
        }
        """
    }
    return """
    guard let \(name) = parameters.firstValue(
        forName: \(key),
        as: \(parameter.wrappedType).self
    ) else {
        return nil
    }
    """
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

private func plainStringArray(_ expression: ExprSyntax) -> [String]? {
    guard let array = expression.as(ArrayExprSyntax.self) else { return nil }
    var values: [String] = []
    for element in array.elements {
        guard let value = plainStringLiteral(element.expression), !value.isEmpty else {
            return nil
        }
        values.append(value)
    }
    return values
}

private func deepLinkPatternLiteral(_ attribute: AttributeSyntax) -> String? {
    guard case .argumentList(let arguments) = attribute.arguments,
          arguments.count == 1,
          let argument = arguments.first,
          argument.label == nil else {
        return nil
    }
    return plainStringLiteral(argument.expression).flatMap { $0.isEmpty ? nil : $0 }
}

private func plainStringLiteral(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
          literal.openingQuote.text == "\"",
          literal.closingQuote.text == "\"",
          literal.segments.count == 1,
          let segment = literal.segments.first?.as(StringSegmentSyntax.self) else {
        return nil
    }
    let value = segment.content.text
    guard expression.trimmedDescription == swiftStringLiteral(value) else { return nil }
    return value
}

private func deepLinkAttributes(on caseDecl: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    caseDecl.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              deepLinkAttributeName(attribute) == "DeepLink" else {
            return nil
        }
        return attribute
    }
}

private func containsDeepLinkAttribute(on caseDecl: EnumCaseDeclSyntax) -> Bool {
    !deepLinkAttributes(on: caseDecl).isEmpty || conditionalDeepLinkAttribute(on: caseDecl) != nil
}

private func conditionalDeepLinkAttribute(
    on caseDecl: EnumCaseDeclSyntax
) -> AttributeSyntax? {
    caseDecl.attributes.lazy.compactMap { element in
        guard let conditional = element.as(IfConfigDeclSyntax.self) else { return nil }
        return firstAttribute(named: "DeepLink", inside: conditional)
    }.first
}

private func firstAttribute(
    named name: String,
    inside conditional: IfConfigDeclSyntax
) -> AttributeSyntax? {
    for clause in conditional.clauses {
        guard case .attributes(let attributes) = clause.elements else { continue }
        for element in attributes {
            if let attribute = element.as(AttributeSyntax.self),
               deepLinkAttributeName(attribute) == name {
                return attribute
            }
            if let nestedConditional = element.as(IfConfigDeclSyntax.self),
               let attribute = firstAttribute(named: name, inside: nestedConditional) {
                return attribute
            }
        }
    }
    return nil
}

private func deepLinkAttributeName(_ attribute: AttributeSyntax) -> String? {
    attribute.attributeName.trimmedDescription
        .split(separator: ".")
        .last
        .map(String.init)
}

private func hasDeepLinkAvailabilityAttribute(_ caseDecl: EnumCaseDeclSyntax) -> Bool {
    caseDecl.attributes.contains { element in
        if let attribute = element.as(AttributeSyntax.self) {
            return deepLinkAttributeName(attribute) == "available"
        }
        if let conditional = element.as(IfConfigDeclSyntax.self) {
            return firstAttribute(named: "available", inside: conditional) != nil
        }
        return false
    }
}

private func deepLinkCasesInsideConditional(
    _ conditional: IfConfigDeclSyntax
) -> [EnumCaseDeclSyntax] {
    var result: [EnumCaseDeclSyntax] = []
    collectDeepLinkConditionalCases(in: Syntax(conditional), into: &result)
    return result
}

private func collectDeepLinkConditionalCases(
    in syntax: Syntax,
    into result: inout [EnumCaseDeclSyntax]
) {
    if let caseDecl = syntax.as(EnumCaseDeclSyntax.self) {
        result.append(caseDecl)
        return
    }
    if syntax.is(EnumDeclSyntax.self) { return }
    for child in syntax.children(viewMode: .sourceAccurate) {
        collectDeepLinkConditionalCases(in: child, into: &result)
    }
}

private func conflictingDeepLinkResolver(
    in enumDecl: EnumDeclSyntax
) -> FunctionDeclSyntax? {
    for member in enumDecl.memberBlock.members {
        if let function = member.decl.as(FunctionDeclSyntax.self),
           function.name.text == "resolveDeepLink",
           function.genericParameterClause == nil,
           function.modifiers.contains(where: { modifier in
               modifier.name.tokenKind == .keyword(.static) ||
                   modifier.name.tokenKind == .keyword(.class)
           }),
           function.signature.parameterClause.parameters.count == 1,
           let parameter = function.signature.parameterClause.parameters.first,
           parameter.firstName.tokenKind == .wildcard,
           isFoundationURLType(parameter.type) {
            return function
        }
    }
    return nil
}

private func isFoundationURLType(_ type: TypeSyntax) -> Bool {
    let spelling = type.trimmedDescription
    return spelling == "URL" || spelling == "Foundation.URL" || spelling == "FoundationEssentials.URL"
}

private func isValidDeepLinkScheme(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first, isASCIILetter(first) else { return false }
    return value.unicodeScalars.dropFirst().allSatisfy { scalar in
        isASCIILetter(scalar) || isASCIIDigit(scalar) || "+-.".unicodeScalars.contains(scalar)
    }
}

private func isValidDeepLinkHost(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 253,
          value.unicodeScalars.allSatisfy({ $0.isASCII }) else {
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

private func isASCIIIdentifier(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
          isASCIILetter(first) || first == "_" else {
        return false
    }
    return value.unicodeScalars.dropFirst().allSatisfy { scalar in
        isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "_"
    }
}

private func isURLPathLiteralScalar(_ scalar: Unicode.Scalar) -> Bool {
    isASCIIAlphaNumeric(scalar) || "-._~".unicodeScalars.contains(scalar)
}

private func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    isASCIILetter(scalar) || isASCIIDigit(scalar)
}

private func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
}

private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    (48 ... 57).contains(scalar.value)
}

private func swiftStringLiteral(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private func indentEveryLine(_ value: String, by spaces: Int) -> String {
    let indentation = String(repeating: " ", count: spaces)
    return value
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { indentation + String($0) }
        .joined(separator: "\n")
}

private func indentContinuationLines(_ value: String, by spaces: Int) -> String {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first else { return value }
    let indentation = String(repeating: " ", count: spaces)
    return ([String(first)] + lines.dropFirst().map { indentation + String($0) })
        .joined(separator: "\n")
}
