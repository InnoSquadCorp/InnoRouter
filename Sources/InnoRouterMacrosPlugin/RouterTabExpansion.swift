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
    let directlyConformsToRouterTabRoute: Bool
}

struct RouterTabItem {
    let name: String
    let titleExpression: String
    let systemImageExpression: String
    let selectedSystemImageExpression: String?
    let roleExpression: String?
}

private let generatedRouterTabMemberNames: Set<String> = [
    "Tab",
    "routerTabs",
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
            continue
        }
        guard attributes.count == 1, let attribute = attributes.first else {
            if let duplicate = duplicateAttributeDiagnosis(attributes, in: caseDecl) {
                diagnoseTabItem(
                    .duplicateTabItem,
                    at: duplicate.anchor,
                    context: context,
                    fixIts: duplicate.fixIts
                )
            }
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
                    systemImageExpression: metadata.systemImageExpression,
                    selectedSystemImageExpression: metadata.selectedSystemImageExpression,
                    roleExpression: metadata.roleExpression
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

    let directlyConformsToRouterTabRoute = directlyConforms(enumDecl, to: "RouterTabRoute")
    if directlyConformsToRouterTabRoute, let inheritanceClause = enumDecl.inheritanceClause {
        diagnoseTabItem(
            .redundantRouterTabConformance,
            at: inheritanceClause,
            context: context
        )
    }

    return .valid(
        RouterTabSpecification(
            items: items,
            directlyConformsToRouterTabRoute: directlyConformsToRouterTabRoute
        )
    )
}

func renderRouterTabMembers(
    from specification: RouterTabSpecification,
    access: String
) -> String {
    let descriptors = specification.items
        .map { ".init(tab: .\($0.name), root: .\($0.name))" }
        .joined(separator: ", ")
    var lines = [
        "\(access) enum Tab: Swift.String, InnoRouterSwiftUI.RouterTab {",
    ]
    for item in specification.items {
        lines.append("    case \(item.name)")
    }
    lines.append(contentsOf: [
        "",
        "    \(access) var title: Foundation.LocalizedStringResource {",
        "        switch self {",
    ])
    for item in specification.items {
        lines.append("        case .\(item.name):")
        lines.append("            return \(item.titleExpression)")
    }
    lines.append(contentsOf: [
        "        }",
        "    }",
        "",
        "    \(access) var systemImage: Swift.String {",
        "        switch self {",
    ])
    for item in specification.items {
        lines.append("        case .\(item.name):")
        lines.append("            return \(item.systemImageExpression)")
    }
    lines.append(contentsOf: [
        "        }",
        "    }",
    ])
    if specification.items.contains(where: { $0.selectedSystemImageExpression != nil }) {
        lines.append(contentsOf: [
            "",
            "    \(access) var selectedSystemImage: Swift.String? {",
            "        switch self {",
        ])
        for item in specification.items {
            let expression = item.selectedSystemImageExpression ?? "nil"
            lines.append("        case .\(item.name):")
            lines.append("            return \(expression)")
        }
        lines.append(contentsOf: [
            "        }",
            "    }",
        ])
    }
    if specification.items.contains(where: { $0.roleExpression != nil }) {
        lines.append(contentsOf: [
            "",
            "    \(access) var role: InnoRouterSwiftUI.RouterTabRole {",
            "        switch self {",
        ])
        for item in specification.items {
            let expression = item.roleExpression ?? ".standard"
            lines.append("        case .\(item.name):")
            lines.append("            return \(expression)")
        }
        lines.append(contentsOf: [
            "        }",
            "    }",
        ])
    }
    lines.append(contentsOf: [
        "",
        "    \(access) var routerScopeID: InnoRouterCore.RouterScopeID {",
        "        InnoRouterCore.RouterScopeID(rawValue)",
        "    }",
        "}",
        "",
        "\(access) static var routerTabs: [InnoRouterSwiftUI.RouterTabDescriptor<Self, Tab>] {",
        "    [\(descriptors)]",
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
    let selectedSystemImageExpression: String?
    let roleExpression: String?
}

private enum TabItemParseResult {
    case success(ParsedTabItem)
    case failure(String)
}

private func parseTabItem(_ attribute: AttributeSyntax) -> TabItemParseResult {
    guard case .argumentList(let arguments) = attribute.arguments,
          (2...4).contains(arguments.count),
          let titleArgument = arguments.first else {
        return .failure("provide a title, `systemImage:`, and optional selected image or role")
    }
    guard titleArgument.label == nil else {
        return .failure("the title must be the first unlabeled argument")
    }
    guard isNonemptyPlainStringLiteral(titleArgument.expression) else {
        return .failure("the title must be a nonempty plain string literal")
    }
    let labeledArguments = Array(arguments.dropFirst())
    let labels = labeledArguments.compactMap { $0.label?.text }
    guard labels.count == labeledArguments.count,
          Set(labels).count == labels.count,
          Set(labels).isSubset(of: ["systemImage", "selectedSystemImage", "role"]) else {
        return .failure("use `systemImage:`, `selectedSystemImage:`, and `role:` at most once")
    }
    guard let systemImageArgument = labeledArguments.first(where: {
        $0.label?.text == "systemImage"
    }) else {
        return .failure("`systemImage:` is required")
    }
    guard isNonemptyPlainStringLiteral(systemImageArgument.expression) else {
        return .failure("systemImage must be a nonempty plain string literal")
    }
    let selectedImageArgument = labeledArguments.first {
        $0.label?.text == "selectedSystemImage"
    }
    if let selectedImageArgument,
       !isNonemptyPlainStringLiteral(selectedImageArgument.expression) {
        return .failure("selectedSystemImage must be a nonempty plain string literal")
    }
    let roleArgument = labeledArguments.first { $0.label?.text == "role" }
    if let roleArgument, !isSupportedTabRole(roleArgument.expression) {
        return .failure("role must be `.standard` or `.search`")
    }

    return .success(
        ParsedTabItem(
            titleExpression: titleArgument.expression.trimmedDescription,
            systemImageExpression: systemImageArgument.expression.trimmedDescription,
            selectedSystemImageExpression: selectedImageArgument?.expression.trimmedDescription,
            roleExpression: roleArgument?.expression.trimmedDescription
        )
    )
}

private func isSupportedTabRole(_ expression: ExprSyntax) -> Bool {
    let value = expression.trimmedDescription
    return value == ".standard" || value == ".search"
        || value.hasSuffix("RouterTabRole.standard")
        || value.hasSuffix("RouterTabRole.search")
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
    let declaration: DeclSyntax
}

private func firstConflictingTabMember(in enumDecl: EnumDeclSyntax) -> ConflictingTabMember? {
    guard let conflict = firstRouterGeneratedMemberConflict(
        in: enumDecl.memberBlock.members,
        typeMembers: generatedRouterTabMemberNames,
        staticMembers: generatedRouterTabMemberNames
    ) else {
        return nil
    }
    return ConflictingTabMember(name: conflict.name, declaration: conflict.declaration)
}
