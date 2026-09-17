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

import SwiftParser
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
    extractCasePathEnumCases(
        from: enumDecl.memberBlock.members,
        enumName: escapedIdentifier(enumDecl.name)
    )
}

internal func extractCasePathEnumCases(
    from members: MemberBlockItemListSyntax,
    enumName: String
) -> [CasePathEnumCase] {
    members.flatMap { member -> [CasePathEnumCase] in
        if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
            return extractCasePathEnumCases(from: caseDecl, enumName: enumName)
        }
        if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
            return conditional.clauses.flatMap { clause -> [CasePathEnumCase] in
                guard case .decls(let members) = clause.elements else { return [] }
                return extractCasePathEnumCases(from: members, enumName: enumName)
            }
        }
        return []
    }
}

internal func extractCasePathEnumCases(
    from caseDecl: EnumCaseDeclSyntax,
    enumName: String
) -> [CasePathEnumCase] {
    let availability = availabilityAttributes(from: caseDecl)
    return caseDecl.elements.map { enumCase in
        CasePathEnumCase(
            name: enumCase.name.text,
            emittedName: escapedIdentifier(enumCase.name),
            availabilityAttributes: availability,
            parameters: associatedValueParameters(
                enumCase.parameterClause?.parameters,
                enumName: enumName
            )
        )
    }
}

private func associatedValueParameters(
    _ parameters: EnumCaseParameterListSyntax?,
    enumName: String
) -> [CasePathAssociatedValueParameter] {
    guard let parameters else { return [] }
    var usedNames: Set<String> = []
    return parameters.enumerated().map { index, parameter in
        let preferredName = bindingName(for: parameter, index: index)
        let uniqueName = allocateUniqueBindingName(
            preferredName,
            index: index,
            generatedPrefix: "__innoRouterCaseValue",
            usedNames: &usedNames
        )
        return CasePathAssociatedValueParameter(
            type: casePathPayloadType(parameter.type, enumName: enumName),
            bindingName: uniqueName,
            emittedLabel: emittedLabel(for: parameter)
        )
    }
}

private final class CasePathSelfTypeRewriter: SyntaxRewriter {
    private let enumName: String

    init(enumName: String) {
        self.enumName = enumName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ token: TokenSyntax) -> TokenSyntax {
        guard token.tokenKind == .keyword(.Self) else { return token }
        return TokenSyntax(
            .identifier(enumName),
            leadingTrivia: token.leadingTrivia,
            trailingTrivia: token.trailingTrivia,
            presence: token.presence
        )
    }
}

internal func casePathPayloadType(_ type: TypeSyntax, enumName: String) -> String {
    CasePathSelfTypeRewriter(enumName: enumName)
        .rewrite(Syntax(type))
        .trimmedDescription
}

// MARK: - Identifier helpers

internal func escapedIdentifier(_ token: TokenSyntax) -> String {
    let spelling = token.trimmedDescription
    if spelling.hasPrefix("`"), spelling.hasSuffix("`") {
        return spelling
    }
    return token.text
}

/// Returns `token` spelled so it is valid where Swift requires a *binding*
/// name — a `let` pattern or a parameter's internal name.
///
/// Swift accepts a bare keyword as an argument *label* (`case detail(in: Int)`
/// is legal), but rejects the same spelling as a binding name. `escapedIdentifier`
/// only preserves backticks the author already wrote, so reusing its result as a
/// binding emitted `let in`, which fails to parse inside the expansion.
///
/// The token kind cannot be used to detect this: `SwiftParser.parseArgumentLabel()`
/// remaps a keyword label to `.identifier`, so `case detail(in:)` and
/// `case detail(id:)` arrive with the same `tokenKind`. The spelling is therefore
/// probed against the parser and backticked only when it would not bind.
internal func escapedBindingIdentifier(_ token: TokenSyntax) -> String {
    escapedBindingSpelling(escapedIdentifier(token))
}

/// Backticks `spelling` unless it is already escaped or already binds.
internal func escapedBindingSpelling(_ spelling: String) -> String {
    guard !spelling.hasPrefix("`") else { return spelling }
    guard !bindsAsIdentifier(spelling) else { return spelling }
    return "`\(spelling)`"
}

/// Whether `spelling` can be written bare in a binding position.
private func bindsAsIdentifier(_ spelling: String) -> Bool {
    let source = Parser.parse(source: "let \(spelling) = 0")
    guard !source.hasError,
          source.statements.count == 1,
          let declaration = source.statements.first?.item.as(VariableDeclSyntax.self),
          declaration.bindings.count == 1,
          let pattern = declaration.bindings.first?.pattern.as(IdentifierPatternSyntax.self)
    else {
        return false
    }
    return pattern.identifier.text == spelling
}

internal func bindingName(
    for param: EnumCaseParameterSyntax,
    index: Int
) -> String {
    if let firstName = param.firstName, firstName.text != "_" {
        return escapedBindingIdentifier(firstName)
    }

    return param.secondName.map(escapedBindingIdentifier) ?? "v\(index)"
}

internal func emittedLabel(for param: EnumCaseParameterSyntax) -> String? {
    guard let firstName = param.firstName, firstName.text != "_" else {
        return nil
    }

    return labelSpelling(escapedIdentifier(firstName))
}

/// Returns `spelling` as it should appear in an argument *label* position.
///
/// The inverse of ``escapedBindingSpelling``. An argument label accepts a bare
/// keyword, and escaping one there is not just unnecessary but warns —
/// "keyword 'default' does not need to be escaped in argument list". An author
/// who writes `case foo(`default`: Int)` has to escape it in the declaration,
/// but carrying those backticks into the generated call site produced a
/// warning in their build that they could not silence.
///
/// Backticks are dropped only when the bare spelling actually parses as a
/// label, so a keyword that genuinely needs escaping keeps it.
internal func labelSpelling(_ spelling: String) -> String {
    guard spelling.hasPrefix("`"), spelling.hasSuffix("`") else { return spelling }
    let bare = unescapedIdentifier(spelling)
    guard parsesAsArgumentLabel(bare) else { return spelling }
    return bare
}

/// Whether `text` can be written bare as an argument label.
private func parsesAsArgumentLabel(_ text: String) -> Bool {
    let source = Parser.parse(source: "call(\(text): 0)")
    guard !source.hasError,
          source.statements.count == 1,
          let call = source.statements.first?.item.as(FunctionCallExprSyntax.self),
          call.arguments.count == 1,
          let label = call.arguments.first?.label
    else {
        return false
    }
    return label.text == text
}

internal func allocateUniqueBindingName(
    _ preferredName: String,
    index: Int,
    generatedPrefix: String,
    usedNames: inout Set<String>
) -> String {
    if usedNames.insert(unescapedIdentifier(preferredName)).inserted {
        return preferredName
    }
    var suffix = index
    var candidate: String
    repeat {
        candidate = "\(generatedPrefix)\(suffix)"
        suffix += 1
    } while !usedNames.insert(candidate).inserted
    return candidate
}

internal func unescapedIdentifier(_ name: String) -> String {
    guard name.hasPrefix("`"), name.hasSuffix("`") else { return name }
    return String(name.dropFirst().dropLast())
}

// MARK: - Availability passthrough

private func availabilityAttributes(
    from caseDecl: EnumCaseDeclSyntax
) -> [String] {
    caseDecl.attributes.compactMap { element -> String? in
        if let attribute = element.as(AttributeSyntax.self),
           attributeBaseName(attribute) == "available" {
            return attribute.trimmedDescription
        }
        if let conditional = element.as(IfConfigDeclSyntax.self),
           let rendered = renderConditionalCasePathAvailability(conditional) {
            return rendered
        }
        return nil
    }
}

private func renderConditionalCasePathAvailability(
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
                      let rendered = renderConditionalCasePathAvailability(nested) {
                lines.append(rendered)
            }
        }
    }
    lines.append(conditional.poundEndif.text)
    return lines.joined(separator: "\n")
}
