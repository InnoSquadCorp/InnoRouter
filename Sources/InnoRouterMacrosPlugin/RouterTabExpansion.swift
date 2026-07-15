// MARK: - RouterTabExpansion.swift
// InnoRouterMacrosPlugin - @Router tab analysis and witness generation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxMacros

enum RouterTabExpansion {
    case none
    case invalid
    case valid(RouterTabSpecification)
}

struct RouterTabSpecification {
    let items: [RouterTabItem]
    let directlyConformsToRouterTab: Bool
}

struct RouterTabItem {
    let name: String
    let titleExpression: String
    let systemImageExpression: String
}

private let generatedRouterTabMemberNames: Set<String> = [
    "allCases",
    "title",
    "systemImage",
]

func analyzeRouterTabs(
    in enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) -> RouterTabExpansion {
    let directCases = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    let conditionalCases = enumDecl.memberBlock.members.flatMap { member in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else {
            return [EnumCaseDeclSyntax]()
        }
        return enumCasesInsideConditional(conditional)
    }
    let allCases = directCases + conditionalCases

    guard allCases.contains(where: containsTabItemAttribute) else {
        return .none
    }

    if let conditionalCase = conditionalCases.first {
        diagnoseTabItem(.conditionalCase, at: conditionalCase, context: context)
        return .invalid
    }

    if let conditionalAttribute = directCases.lazy.compactMap({
        conditionalTabItemAttribute(on: $0)
    }).first {
        diagnoseTabItem(.conditionalCase, at: conditionalAttribute, context: context)
        return .invalid
    }

    var items: [RouterTabItem] = []
    for caseDecl in directCases {
        let attributes = tabItemAttributes(on: caseDecl)
        guard !attributes.isEmpty else {
            let name = caseDecl.elements.first?.name.text ?? "<unknown>"
            diagnoseTabItem(.missingTabItem(caseName: name), at: caseDecl, context: context)
            return .invalid
        }
        guard attributes.count == 1, let attribute = attributes.first else {
            diagnoseTabItem(.duplicateTabItem, at: attributes[1], context: context)
            return .invalid
        }
        guard caseDecl.elements.count == 1, let element = caseDecl.elements.first else {
            diagnoseTabItem(.multipleCasesPerDeclaration, at: caseDecl, context: context)
            return .invalid
        }
        guard !generatedRouterTabMemberNames.contains(element.name.text) else {
            diagnoseTabItem(
                .conflictingMember(name: element.name.text),
                at: element,
                context: context
            )
            return .invalid
        }
        guard !hasAvailabilityAttribute(caseDecl) else {
            diagnoseTabItem(
                .unavailableCase(caseName: element.name.text),
                at: caseDecl,
                context: context
            )
            return .invalid
        }
        guard element.parameterClause == nil else {
            diagnoseTabItem(
                .associatedValues(caseName: element.name.text),
                at: element,
                context: context
            )
            return .invalid
        }

        switch parseTabItem(attribute) {
        case .success(let metadata):
            items.append(
                RouterTabItem(
                    name: escapedIdentifier(element.name),
                    titleExpression: metadata.titleExpression,
                    systemImageExpression: metadata.systemImageExpression
                )
            )
        case .failure(let reason):
            diagnoseTabItem(.invalidArguments(reason: reason), at: attribute, context: context)
            return .invalid
        }
    }

    if let conflict = firstConflictingTabMember(in: enumDecl) {
        diagnoseTabItem(
            .conflictingMember(name: conflict.name),
            at: conflict.declaration,
            context: context
        )
        return .invalid
    }

    let directlyConformsToRouterTab = directlyConforms(enumDecl, to: "RouterTab")
    if directlyConformsToRouterTab, let inheritanceClause = enumDecl.inheritanceClause {
        diagnoseTabItem(
            .redundantRouterTabConformance,
            at: inheritanceClause,
            context: context
        )
    } else if directlyConforms(enumDecl, to: "CaseIterable"),
              let inheritanceClause = enumDecl.inheritanceClause {
        diagnoseTabItem(
            .redundantCaseIterableConformance,
            at: inheritanceClause,
            context: context
        )
    }

    return .valid(
        RouterTabSpecification(
            items: items,
            directlyConformsToRouterTab: directlyConformsToRouterTab
        )
    )
}

func renderRouterTabMembers(
    from specification: RouterTabSpecification,
    access: String
) -> String {
    let allCases = specification.items
        .map { ".\($0.name)" }
        .joined(separator: ", ")
    var lines = [
        "\(access) static var allCases: [Self] {",
        "    [\(allCases)]",
        "}",
        "",
        "\(access) var title: Swift.String {",
        "    switch self {",
    ]
    for item in specification.items {
        lines.append("    case .\(item.name):")
        lines.append("        return \(item.titleExpression)")
    }
    lines.append(contentsOf: [
        "    }",
        "}",
        "",
        "\(access) var systemImage: Swift.String {",
        "    switch self {",
    ])
    for item in specification.items {
        lines.append("    case .\(item.name):")
        lines.append("        return \(item.systemImageExpression)")
    }
    lines.append(contentsOf: [
        "    }",
        "}",
    ])
    return lines.joined(separator: "\n")
}

func directlyConforms(_ enumDecl: EnumDeclSyntax, to protocolName: String) -> Bool {
    enumDecl.inheritanceClause?.inheritedTypes.contains { inherited in
        inherited.type.trimmedDescription
            .split(separator: ".")
            .last
            .map(String.init) == protocolName
    } ?? false
}

private struct ParsedTabItem {
    let titleExpression: String
    let systemImageExpression: String
}

private enum TabItemParseResult {
    case success(ParsedTabItem)
    case failure(String)
}

private func parseTabItem(_ attribute: AttributeSyntax) -> TabItemParseResult {
    guard case .argumentList(let arguments) = attribute.arguments,
          arguments.count == 2,
          let titleArgument = arguments.first,
          let systemImageArgument = arguments.last else {
        return .failure("provide exactly one unlabeled title and one `systemImage:` argument")
    }
    guard titleArgument.label == nil else {
        return .failure("the title must be the first unlabeled argument")
    }
    guard systemImageArgument.label?.text == "systemImage" else {
        return .failure("the second argument label must be exactly `systemImage:`")
    }
    guard isNonemptyPlainStringLiteral(titleArgument.expression) else {
        return .failure("the title must be a nonempty plain string literal")
    }
    guard isNonemptyPlainStringLiteral(systemImageArgument.expression) else {
        return .failure("systemImage must be a nonempty plain string literal")
    }

    return .success(
        ParsedTabItem(
            titleExpression: titleArgument.expression.trimmedDescription,
            systemImageExpression: systemImageArgument.expression.trimmedDescription
        )
    )
}

private func isNonemptyPlainStringLiteral(_ expression: ExprSyntax) -> Bool {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
          literal.segments.count == 1,
          let segment = literal.segments.first?.as(StringSegmentSyntax.self) else {
        return false
    }
    return segment.content.text.contains(where: { !$0.isWhitespace })
}

private func tabItemAttributes(on caseDecl: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    caseDecl.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              attributeBaseName(attribute) == "TabItem" else {
            return nil
        }
        return attribute
    }
}

private func containsTabItemAttribute(on caseDecl: EnumCaseDeclSyntax) -> Bool {
    !tabItemAttributes(on: caseDecl).isEmpty || conditionalTabItemAttribute(on: caseDecl) != nil
}

private func conditionalTabItemAttribute(on caseDecl: EnumCaseDeclSyntax) -> AttributeSyntax? {
    caseDecl.attributes.lazy.compactMap { element in
        guard let conditional = element.as(IfConfigDeclSyntax.self) else { return nil }
        return firstConditionalAttribute(named: "TabItem", inside: conditional)
    }.first
}

private func hasAvailabilityAttribute(_ caseDecl: EnumCaseDeclSyntax) -> Bool {
    caseDecl.attributes.contains { element in
        if let attribute = element.as(AttributeSyntax.self) {
            return attributeBaseName(attribute) == "available"
        }
        if let conditional = element.as(IfConfigDeclSyntax.self) {
            return firstConditionalAttribute(named: "available", inside: conditional) != nil
        }
        return false
    }
}

private func enumCasesInsideConditional(_ conditional: IfConfigDeclSyntax) -> [EnumCaseDeclSyntax] {
    conditional.clauses.flatMap { clause in
        guard case .decls(let members) = clause.elements else {
            return [EnumCaseDeclSyntax]()
        }
        return members.flatMap { member in
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                return [caseDecl]
            }
            if let nestedConditional = member.decl.as(IfConfigDeclSyntax.self) {
                return enumCasesInsideConditional(nestedConditional)
            }
            return []
        }
    }
}

private struct ConflictingTabMember {
    let name: String
    let declaration: VariableDeclSyntax
}

private func firstConflictingTabMember(in enumDecl: EnumDeclSyntax) -> ConflictingTabMember? {
    let directVariables = enumDecl.memberBlock.members.compactMap({
        $0.decl.as(VariableDeclSyntax.self)
    })
    let conditionalVariables = enumDecl.memberBlock.members.flatMap { member in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else {
            return [VariableDeclSyntax]()
        }
        return variablesInsideConditional(conditional)
    }
    for variable in directVariables + conditionalVariables {
        for binding in variable.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  generatedRouterTabMemberNames.contains(identifier) else {
                continue
            }
            return ConflictingTabMember(name: identifier, declaration: variable)
        }
    }
    return nil
}

private func variablesInsideConditional(_ conditional: IfConfigDeclSyntax) -> [VariableDeclSyntax] {
    conditional.clauses.flatMap { clause in
        guard case .decls(let members) = clause.elements else {
            return [VariableDeclSyntax]()
        }
        return members.flatMap { member in
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                return [variable]
            }
            if let nestedConditional = member.decl.as(IfConfigDeclSyntax.self) {
                return variablesInsideConditional(nestedConditional)
            }
            return []
        }
    }
}
