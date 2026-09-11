// MARK: - CasePathEnumIteration.swift
// InnoRouterMacrosPlugin - enum case extraction + identifier
// helpers shared by the @Routable / @CasePathable expansion path.
// Copyright © 2026 Inno Squad. All rights reserved.
//
// This file owns the *iteration* layer of the macro plugin: how
// the syntax tree maps into the value-typed `CasePathEnumCase`
// model that ``buildCasePathMembers`` consumes. It does not emit
// any generated source — that belongs in
// `CasePathMemberGeneration.swift`.
//
// Types and helpers are `internal` rather than `private` because
// the generation file imports them.

import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Model

internal struct CasePathAssociatedValueParameter {
    let type: String
    let bindingName: String
    let emittedLabel: String?
}

internal struct CasePathEnumCase {
    let name: String
    let emittedName: String
    let availabilityAttributes: [String]
    let parameters: [CasePathAssociatedValueParameter]
}

// MARK: - Access level inference

/// Access level inferred from the enclosing enum declaration.
///
/// `@Routable` / `@CasePathable` previously emitted every member as
/// `public`, which leaked CasePath surface for `internal` and
/// `private` enums. From 4.0.0 the generated members match the
/// enclosing enum's access level so a `private enum` no longer
/// produces a public CasePath table.
internal enum InferredAccessLevel {
    case `public`
    case `package`
    case `internal`
    case `fileprivate`
    case `private`

    var keyword: String {
        switch self {
        case .public: return "public"
        case .package: return "package"
        case .internal: return "internal"
        case .fileprivate: return "fileprivate"
        case .private: return "fileprivate"
            // Note: `private` enums still need their generated
            // members at fileprivate so the same-file `is` and
            // `subscript` callers can reach them.
        }
    }
}

internal func inferAccessLevel(from enumDecl: EnumDeclSyntax) -> InferredAccessLevel {
    for modifier in enumDecl.modifiers {
        switch modifier.name.tokenKind {
        case .keyword(.public): return .public
        case .keyword(.package): return .package
        case .keyword(.internal): return .internal
        case .keyword(.fileprivate): return .fileprivate
        case .keyword(.private): return .private
        default: continue
        }
    }
    return .internal
}

// MARK: - Case extraction

internal func extractCasePathEnumCases(
    from enumDecl: EnumDeclSyntax
) -> [CasePathEnumCase] {
    extractCasePathEnumCases(from: enumDecl.memberBlock.members)
}

internal func extractCasePathEnumCases(
    from members: MemberBlockItemListSyntax
) -> [CasePathEnumCase] {
    members.flatMap { member -> [CasePathEnumCase] in
        if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
            return extractCasePathEnumCases(from: caseDecl)
        }
        if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
            return conditional.clauses.flatMap { clause -> [CasePathEnumCase] in
                guard case .decls(let members) = clause.elements else { return [] }
                return extractCasePathEnumCases(from: members)
            }
        }
        return []
    }
}

internal func extractCasePathEnumCases(
    from caseDecl: EnumCaseDeclSyntax
) -> [CasePathEnumCase] {
    let availability = availabilityAttributes(from: caseDecl)
    return caseDecl.elements.map { enumCase in
        CasePathEnumCase(
            name: enumCase.name.text,
            emittedName: escapedIdentifier(enumCase.name),
            availabilityAttributes: availability,
            parameters: enumCase.parameterClause?.parameters.enumerated().map { index, param in
                CasePathAssociatedValueParameter(
                    type: param.type.trimmedDescription,
                    bindingName: bindingName(for: param, index: index),
                    emittedLabel: emittedLabel(for: param)
                )
            } ?? []
        )
    }
}

// MARK: - Identifier helpers

internal func escapedIdentifier(_ token: TokenSyntax) -> String {
    let spelling = token.trimmedDescription
    if spelling.hasPrefix("`"), spelling.hasSuffix("`") {
        return spelling
    }
    return token.text
}

internal func bindingName(
    for param: EnumCaseParameterSyntax,
    index: Int
) -> String {
    if let firstName = param.firstName, firstName.text != "_" {
        return escapedIdentifier(firstName)
    }

    return param.secondName.map(escapedIdentifier) ?? "v\(index)"
}

internal func emittedLabel(for param: EnumCaseParameterSyntax) -> String? {
    guard let firstName = param.firstName, firstName.text != "_" else {
        return nil
    }

    return escapedIdentifier(firstName)
}

// MARK: - Availability passthrough

private func availabilityAttributes(
    from caseDecl: EnumCaseDeclSyntax
) -> [String] {
    caseDecl.attributes.compactMap { attribute -> String? in
        guard let attr = attribute.as(AttributeSyntax.self) else { return nil }
        let name = attr.attributeName.trimmedDescription
        guard name == "available" else { return nil }
        return attr.trimmedDescription
    }
}
