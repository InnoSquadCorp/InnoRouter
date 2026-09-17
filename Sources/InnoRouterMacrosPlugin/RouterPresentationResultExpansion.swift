// MARK: - RouterPresentationResultExpansion.swift
// InnoRouterMacrosPlugin - typed presentation request generation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum RouterPresentationResultExpansion {
    case none
    case invalid
    case valid([RouterPresentationResultItem])
}

struct RouterPresentationResultItem {
    let caseName: String
    let resultType: String
    let parameters: [RouterPresentationResultParameter]
    let availabilityAttributes: [String]
}

struct RouterPresentationResultParameter {
    let declaration: String
    let invocation: String
}

enum RouterPresentationResultDiagnostic: DiagnosticMessage {
    case requiresCase
    case requiresRouter
    case duplicate
    case multipleCasesPerDeclaration
    case conditionalCase
    case invalidArguments
    case generatedMemberConflict

    var severity: DiagnosticSeverity { .error }

    private var code: String {
        switch self {
        case .requiresCase: return "InnoRouterMacro.E051"
        case .requiresRouter: return "InnoRouterMacro.E052"
        case .duplicate: return "InnoRouterMacro.E053"
        case .multipleCasesPerDeclaration: return "InnoRouterMacro.E054"
        case .conditionalCase: return "InnoRouterMacro.E055"
        case .invalidArguments: return "InnoRouterMacro.E056"
        case .generatedMemberConflict: return "InnoRouterMacro.E057"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .requiresCase:
            return prefix + "@PresentationResult can only be attached to an enum case"
        case .requiresRouter:
            return prefix + "@PresentationResult requires the nearest enclosing enum to use @Router"
        case .duplicate:
            return prefix + "a route case must have exactly one @PresentationResult annotation"
        case .multipleCasesPerDeclaration:
            return prefix + "@PresentationResult requires one case per declaration"
        case .conditionalCase:
            return prefix + "@PresentationResult cases cannot be declared inside #if"
        case .invalidArguments:
            return prefix + "@PresentationResult requires exactly one result metatype, for example `LoginResult.self`"
        case .generatedMemberConflict:
            return prefix + "@Router generates `Presentation`; rename the conflicting declaration or remove @PresentationResult"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: code)
    }
}

/// Empty peer marker consumed by ``RouterMacro``.
public struct PresentationResultMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumCaseDeclSyntax.self) else {
            diagnosePresentationResult(.requiresCase, at: node, context: context)
            return []
        }
        guard context.lexicalContext.lazy.compactMap({ $0.as(EnumDeclSyntax.self) })
            .first.map(hasRouterAttributeForPresentationResult) == true else {
            diagnosePresentationResult(.requiresRouter, at: node, context: context)
            return []
        }
        return []
    }
}

func analyzeRouterPresentationResults(
    in enumDecl: EnumDeclSyntax,
    routeType: String,
    context: some MacroExpansionContext
) -> RouterPresentationResultExpansion {
    if enumDecl.memberBlock.members.contains(where: { member in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else { return false }
        return firstConditionalEnumCaseAttribute(
            named: "PresentationResult",
            inside: conditional
        ) != nil
    }) {
        diagnosePresentationResult(.conditionalCase, at: enumDecl, context: context)
        return .invalid
    }

    let caseDeclarations = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    let annotated = caseDeclarations.filter {
        presentationResultAttributes(on: $0).isEmpty == false
    }
    guard !annotated.isEmpty else { return .none }

    if let conflict = enumDecl.memberBlock.members.first(where: { member in
        if let declaration = member.decl.as(EnumDeclSyntax.self) {
            return declaration.name.text == "Presentation"
        }
        if let declaration = member.decl.as(StructDeclSyntax.self) {
            return declaration.name.text == "Presentation"
        }
        if let declaration = member.decl.as(ClassDeclSyntax.self) {
            return declaration.name.text == "Presentation"
        }
        if let declaration = member.decl.as(TypeAliasDeclSyntax.self) {
            return declaration.name.text == "Presentation"
        }
        return false
    }) {
        diagnosePresentationResult(.generatedMemberConflict, at: conflict, context: context)
        return .invalid
    }

    var items: [RouterPresentationResultItem] = []
    for caseDeclaration in annotated {
        let attributes = presentationResultAttributes(on: caseDeclaration)
        guard attributes.count == 1, let attribute = attributes.first else {
            diagnosePresentationResult(.duplicate, at: attributes[1], context: context)
            return .invalid
        }
        guard caseDeclaration.elements.count == 1,
              let element = caseDeclaration.elements.first else {
            diagnosePresentationResult(
                .multipleCasesPerDeclaration,
                at: caseDeclaration,
                context: context
            )
            return .invalid
        }
        guard let rawResultType = presentationResultType(from: attribute) else {
            diagnosePresentationResult(.invalidArguments, at: attribute, context: context)
            return .invalid
        }

        let resultType = casePathPayloadType(
            TypeSyntax(stringLiteral: rawResultType),
            enumName: routeType
        )
        let parameters = presentationResultParameters(
            element.parameterClause?.parameters,
            routeType: routeType
        )
        items.append(
            RouterPresentationResultItem(
                caseName: escapedIdentifier(element.name),
                resultType: resultType,
                parameters: parameters,
                availabilityAttributes: presentationResultAvailabilityAttributes(
                    on: caseDeclaration
                )
            )
        )
    }
    return .valid(items)
}

func renderRouterPresentationResultMembers(
    from items: [RouterPresentationResultItem],
    routeType: String,
    access: String
) -> String {
    var lines = ["\(access) enum Presentation {"]
    for item in items {
        let requestType = "InnoRouterCore.RouterPresentationRequest<\(routeType), \(item.resultType)>"
        for availability in item.availabilityAttributes {
            lines.append(contentsOf: availability.split(separator: "\n").map { "    \($0)" })
        }
        if item.parameters.isEmpty {
            lines.append("    \(access) static var \(item.caseName): \(requestType) {")
            lines.append("        .init(route: .\(item.caseName))")
        } else {
            let declaration = item.parameters.map(\.declaration).joined(separator: ", ")
            let invocation = item.parameters.map(\.invocation).joined(separator: ", ")
            lines.append("    \(access) static func \(item.caseName)(\(declaration)) -> \(requestType) {")
            lines.append("        .init(route: .\(item.caseName)(\(invocation)))")
        }
        lines.append("    }")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
}

private func presentationResultAvailabilityAttributes(
    on declaration: EnumCaseDeclSyntax
) -> [String] {
    declaration.attributes.compactMap { element in
        if let attribute = element.as(AttributeSyntax.self),
           attributeBaseName(attribute) == "available" {
            return attribute.trimmedDescription
        }
        if let conditional = element.as(IfConfigDeclSyntax.self),
           let rendered = renderConditionalPresentationAvailability(conditional) {
            return rendered
        }
        return nil
    }
}

private func renderConditionalPresentationAvailability(
    _ conditional: IfConfigDeclSyntax
) -> String? {
    guard firstConditionalAttribute(named: "available", inside: conditional) != nil else {
        return nil
    }
    var lines: [String] = []
    for clause in conditional.clauses {
        var directive = clause.poundKeyword.text
        if let condition = clause.condition?.trimmedDescription {
            directive += " \(condition)"
        }
        lines.append(directive)
        guard case .attributes(let attributes) = clause.elements else { continue }
        for element in attributes {
            if let attribute = element.as(AttributeSyntax.self),
               attributeBaseName(attribute) == "available" {
                lines.append(attribute.trimmedDescription)
            } else if let nested = element.as(IfConfigDeclSyntax.self),
                      let rendered = renderConditionalPresentationAvailability(nested) {
                lines.append(rendered)
            }
        }
    }
    lines.append(conditional.poundEndif.text)
    return lines.joined(separator: "\n")
}

private func presentationResultAttributes(on declaration: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    declaration.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              attributeBaseName(attribute) == "PresentationResult" else {
            return nil
        }
        return attribute
    }
}

private func presentationResultType(from attribute: AttributeSyntax) -> String? {
    guard case .argumentList(let arguments) = attribute.arguments,
          arguments.count == 1,
          let argument = arguments.first,
          argument.label == nil else {
        return nil
    }
    let spelling = argument.expression.trimmedDescription
    guard spelling.hasSuffix(".self") else { return nil }
    let type = String(spelling.dropLast(5))
    return type.isEmpty ? nil : type
}

private func presentationResultParameters(
    _ parameters: EnumCaseParameterListSyntax?,
    routeType: String
) -> [RouterPresentationResultParameter] {
    guard let parameters else { return [] }
    var usedNames: Set<String> = []
    return parameters.enumerated().map { index, parameter in
        // The first name reaches two positions with opposite escaping rules.
        // At a call site it is an argument label, where a bare keyword is
        // legal and a backtick warns ("does not need to be escaped"). In the
        // generated declaration it also names the binding, which a bare
        // keyword cannot spell. Swift treats `in` and `` `in` `` as the same
        // name, so the warning-free declaration is the combined single-name
        // form written escaped — not a `label binding:` pair.
        let firstLabel = parameter.firstName.map(escapedIdentifier)
        let firstBinding = firstLabel.map(escapedBindingSpelling)
        let second = parameter.secondName.map(escapedBindingIdentifier)
        let preferredName: String
        if let second {
            preferredName = second
        } else if let firstBinding, firstLabel != "_" {
            preferredName = firstBinding
        } else {
            preferredName = "value\(index)"
        }
        let localName = allocateUniqueBindingName(
            preferredName,
            index: index,
            generatedPrefix: "__innoRouterPresentationValue",
            usedNames: &usedNames
        )

        let type = casePathPayloadType(parameter.type, enumName: routeType)
        let declaration: String
        let invocation: String
        if let firstLabel, let firstBinding, firstLabel != "_" {
            if second != nil || localName != firstBinding {
                declaration = "\(firstLabel) \(localName): \(type)"
            } else {
                declaration = "\(firstBinding): \(type)"
            }
            invocation = "\(firstLabel): \(localName)"
        } else {
            declaration = "_ \(localName): \(type)"
            invocation = localName
        }
        return RouterPresentationResultParameter(
            declaration: declaration,
            invocation: invocation
        )
    }
}

private func hasRouterAttributeForPresentationResult(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attributeBaseName(attribute) == "Router"
    }
}

private func diagnosePresentationResult(
    _ message: RouterPresentationResultDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: node, message: message))
}
