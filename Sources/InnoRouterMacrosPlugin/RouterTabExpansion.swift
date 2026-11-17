// MARK: - RouterTabExpansion.swift
// InnoRouterMacrosPlugin - @Router tab analysis and witness generation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
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
    let scopeID: String
    let explicitScopeIDExpression: String?
    let attribute: AttributeSyntax
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
                    // The default must equal the generated `Tab` raw value,
                    // which Swift spells without backticks. A sibling `id:`
                    // replaces `RouterScopeID(rawValue)` with per-case
                    // literals, and a literal that kept the author's
                    // backticks silently renamed this tab's persisted scope.
                    scopeID: metadata.scopeID ?? unescapedIdentifier(element.name.text),
                    explicitScopeIDExpression: metadata.scopeIDExpression,
                    attribute: attribute,
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

    if diagnoseDuplicateScopeID(in: items, context: context) {
        return .invalid
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
    diagnoseRouterTabWarnings(
        in: enumDecl, isConformanceRedundant: directlyConformsToRouterTabRoute, context: context
    )

    return .valid(
        RouterTabSpecification(
            items: items,
            directlyConformsToRouterTabRoute: directlyConformsToRouterTabRoute
        )
    )
}

private func diagnoseDuplicateScopeID(
    in items: [RouterTabItem],
    context: some MacroExpansionContext
) -> Bool {
    var seenScopeIDs: Set<String> = []
    guard let duplicate = items.first(where: { !seenScopeIDs.insert($0.scopeID).inserted }) else {
        return false
    }
    diagnoseTabItem(
        .duplicateScopeID(duplicate.scopeID),
        at: duplicate.attribute,
        context: context
    )
    return true
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
    lines.append("")
    lines.append("    \(access) var routerScopeID: InnoRouterCore.RouterScopeID {")
    if specification.items.contains(where: { $0.explicitScopeIDExpression != nil }) {
        lines.append("        switch self {")
        for item in specification.items {
            let expression = item.explicitScopeIDExpression ?? swiftStringLiteral(item.scopeID)
            lines.append("        case .\(item.name):")
            lines.append("            return InnoRouterCore.RouterScopeID(\(expression))")
        }
        lines.append("        }")
    } else {
        lines.append("        InnoRouterCore.RouterScopeID(rawValue)")
    }
    lines.append(contentsOf: [
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
    let scopeID: String?
    let scopeIDExpression: String?
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
          (2...5).contains(arguments.count),
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
          Set(labels).isSubset(of: ["systemImage", "id", "selectedSystemImage", "role"]) else {
        return .failure("use `systemImage:`, `id:`, `selectedSystemImage:`, and `role:` at most once")
    }
    guard let systemImageArgument = labeledArguments.first(where: {
        $0.label?.text == "systemImage"
    }) else {
        return .failure("`systemImage:` is required")
    }
    guard isNonemptyPlainStringLiteral(systemImageArgument.expression) else {
        return .failure("systemImage must be a nonempty plain string literal")
    }
    let idArgument = labeledArguments.first { $0.label?.text == "id" }
    let scopeID: String?
    let scopeIDExpression: String?
    if let idArgument {
        guard let literal = idArgument.expression.as(StringLiteralExprSyntax.self),
              let value = literal.representedLiteralValue,
              value.contains(where: { !$0.isWhitespace }) else {
            return .failure("id must be one nonempty noninterpolated string literal")
        }
        scopeID = value
        scopeIDExpression = idArgument.expression.trimmedDescription
    } else {
        scopeID = nil
        scopeIDExpression = nil
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
            scopeID: scopeID,
            scopeIDExpression: scopeIDExpression,
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

/// Emits the warnings that accompany a valid tab router.
private func diagnoseRouterTabWarnings(
    in enumDecl: EnumDeclSyntax,
    isConformanceRedundant: Bool,
    context: some MacroExpansionContext
) {
    diagnoseRedundantRouterTabConformance(
        in: enumDecl,
        isRedundant: isConformanceRedundant,
        context: context
    )
    diagnoseShadowedSwiftUITabCalls(in: enumDecl, context: context)
}

/// Collects unqualified `Tab(...)` calls that were written for SwiftUI's tab
/// content but resolve to the generated `Tab` instead.
///
/// The compiler reports such a call as an unrelated-looking `ViewBuilder` or
/// argument error, so the macro names the real cause. Only the shape every
/// SwiftUI `Tab` initializer has is flagged: a content closure, written as a
/// trailing closure or a `content:` argument. Any other call, such as
/// `Tab(rawValue:)` or an initializer an extension adds to the generated
/// type, is a legitimate use of that type and is left alone, as is member
/// access such as `Tab.home`.
///
/// An initializer with a content closure that an extension adds to the
/// generated type has the same shape and is reported too; `Self.Tab(...)`
/// names the generated type without the warning.
///
/// The walk stops wherever `Tab` is given another meaning (a nested type, a
/// function body, or a closure that declares its own `Tab` type, function, or
/// value) and at a nested tab router, whose own expansion reports the calls it
/// contains.
final class ShadowedSwiftUITabCallFinder: SyntaxVisitor {
    private(set) var references: [DeclReferenceExprSyntax] = []

    static func references(in enumDecl: EnumDeclSyntax) -> [DeclReferenceExprSyntax] {
        let finder = ShadowedSwiftUITabCallFinder(viewMode: .sourceAccurate)
        finder.walk(enumDecl.memberBlock)
        return finder.references
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
           reference.baseName.text == "Tab",
           node.trailingClosure != nil || node.arguments.contains(where: { $0.label?.text == "content" }) {
            references.append(reference)
        }
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        continuation(for: node.memberBlock)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        continuation(for: node.memberBlock)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        continuation(for: node.memberBlock)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let generatesOwnTab = node.memberBlock.members.contains { member in
            member.decl.as(EnumCaseDeclSyntax.self)?.attributes.contains { attribute in
                attribute.as(AttributeSyntax.self).flatMap(attributeBaseName) == "TabItem"
            } ?? false
        }
        return generatesOwnTab ? .skipChildren : continuation(for: node.memberBlock)
    }

    /// Every body is a statement list: functions, closures, and accessors.
    override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
        rebindsTab(node.map { Syntax($0.item) }) ? .skipChildren : .visitChildren
    }

    /// Skips a type whose own members give `Tab` another meaning.
    private func continuation(for members: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        rebindsTab(members.members.map { Syntax($0.decl) }) ? .skipChildren : .visitChildren
    }

    /// Whether one of `declarations` declares the name `Tab`: a type, a
    /// type alias, a function, or a value such as a stored closure.
    private func rebindsTab(_ declarations: [Syntax]) -> Bool {
        declarations.contains { declaration in
            // A declaration inside any `#if` clause may be the active one;
            // the macro cannot evaluate build conditions, so it assumes so.
            if let conditional = declaration.as(IfConfigDeclSyntax.self) {
                return conditional.clauses.contains { clause in
                    switch clause.elements {
                    case .decls(let members): rebindsTab(members.map { Syntax($0.decl) })
                    case .statements(let items): rebindsTab(items.map { Syntax($0.item) })
                    default: false
                    }
                }
            }
            if let variable = declaration.as(VariableDeclSyntax.self) {
                return variable.bindings.contains {
                    $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "Tab"
                }
            }
            let name = declaration.as(TypeAliasDeclSyntax.self)?.name
                ?? declaration.as(StructDeclSyntax.self)?.name
                ?? declaration.as(ClassDeclSyntax.self)?.name
                ?? declaration.as(EnumDeclSyntax.self)?.name
                ?? declaration.as(ActorDeclSyntax.self)?.name
                ?? declaration.as(FunctionDeclSyntax.self)?.name
            return name?.text == "Tab"
        }
    }
}

/// Warns where the generated `Tab` shadows SwiftUI's `Tab` inside the router
/// enum, offering the qualified spelling. Uses in extensions are outside the
/// macro's view and are covered by documentation only.
private func diagnoseShadowedSwiftUITabCalls(
    in enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) {
    for reference in ShadowedSwiftUITabCallFinder.references(in: enumDecl) {
        let qualified = ExprSyntax(
            MemberAccessExprSyntax(
                base: DeclReferenceExprSyntax(baseName: .identifier("SwiftUI")),
                declName: DeclReferenceExprSyntax(baseName: .identifier("Tab"))
            )
        )
        .with(\.leadingTrivia, reference.leadingTrivia)
        .with(\.trailingTrivia, reference.trailingTrivia)
        diagnoseTabItem(
            .shadowedSwiftUITab(routerName: enumDecl.name.text),
            at: reference,
            context: context,
            fixIts: [
                FixIt(
                    message: QualifySwiftUITabFixIt(),
                    changes: [.replace(oldNode: Syntax(reference), newNode: Syntax(qualified))]
                ),
            ]
        )
    }
}

/// Warns about an explicit `RouterTabRoute` conformance that `@Router` already
/// supplies, offering the removal edit.
private func diagnoseRedundantRouterTabConformance(
    in enumDecl: EnumDeclSyntax,
    isRedundant: Bool,
    context: some MacroExpansionContext
) {
    guard isRedundant, let inheritanceClause = enumDecl.inheritanceClause else { return }
    diagnoseTabItem(
        .redundantRouterTabConformance,
        at: inheritanceClause,
        context: context,
        fixIts: [
            removeConformanceFixIt(
                named: "RouterTabRoute",
                from: inheritanceClause,
                in: enumDecl
            ),
        ].compactMap { $0 }
    )
}
