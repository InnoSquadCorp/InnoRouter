import SwiftSyntax

func plainStringArray(_ expression: ExprSyntax) -> [String]? {
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

func deepLinkPatternLiteral(_ attribute: AttributeSyntax) -> String? {
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

func deepLinkAttributes(on caseDecl: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    caseDecl.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              deepLinkAttributeName(attribute) == "DeepLink" else {
            return nil
        }
        return attribute
    }
}

func containsDeepLinkAttribute(on caseDecl: EnumCaseDeclSyntax) -> Bool {
    !deepLinkAttributes(on: caseDecl).isEmpty || conditionalDeepLinkAttribute(on: caseDecl) != nil
}

func conditionalDeepLinkAttribute(
    on caseDecl: EnumCaseDeclSyntax
) -> AttributeSyntax? {
    caseDecl.attributes.lazy.compactMap { element in
        guard let conditional = element.as(IfConfigDeclSyntax.self) else { return nil }
        return firstConditionalAttribute(named: "DeepLink", inside: conditional)
    }.first
}

private func deepLinkAttributeName(_ attribute: AttributeSyntax) -> String? {
    attributeBaseName(attribute)
}

func hasDeepLinkAvailabilityAttribute(_ caseDecl: EnumCaseDeclSyntax) -> Bool {
    caseDecl.attributes.contains { element in
        if let attribute = element.as(AttributeSyntax.self) {
            return deepLinkAttributeName(attribute) == "available"
        }
        if let conditional = element.as(IfConfigDeclSyntax.self) {
            return firstConditionalAttribute(named: "available", inside: conditional) != nil
        }
        return false
    }
}

func deepLinkCasesInsideConditional(
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

func conflictingDeepLinkResolver(
    in enumDecl: EnumDeclSyntax
) -> FunctionDeclSyntax? {
    let declarations = enumDecl.memberBlock.members.flatMap { member -> [DeclSyntax] in
        if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
            return declarationsInsideDeepLinkConditional(conditional)
        }
        return [member.decl]
    }

    for declaration in declarations {
        if let function = declaration.as(FunctionDeclSyntax.self),
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

private func declarationsInsideDeepLinkConditional(
    _ conditional: IfConfigDeclSyntax
) -> [DeclSyntax] {
    conditional.clauses.flatMap { clause in
        guard case .decls(let members) = clause.elements else {
            return [DeclSyntax]()
        }
        return members.flatMap { member in
            if let nestedConditional = member.decl.as(IfConfigDeclSyntax.self) {
                return declarationsInsideDeepLinkConditional(nestedConditional)
            }
            return [member.decl]
        }
    }
}

private func isFoundationURLType(_ type: TypeSyntax) -> Bool {
    let spelling = type.trimmedDescription
    return spelling == "URL" || spelling == "Foundation.URL" || spelling == "FoundationEssentials.URL"
}
