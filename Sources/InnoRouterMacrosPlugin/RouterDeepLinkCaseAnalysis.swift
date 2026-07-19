// MARK: - RouterDeepLinkCaseAnalysis.swift
// InnoRouterMacrosPlugin - @DeepLink case and parameter validation.

import SwiftSyntax
import SwiftSyntaxMacros

func analyzeDeepLinkCase(
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

enum DeepLinkPatternValidation {
    case success([String])
    case failure(String)
}

func validateDeepLinkPattern(_ pattern: String) -> DeepLinkPatternValidation {
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
