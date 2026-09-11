// MARK: - CasePathMemberBuilder.swift
// InnoRouterMacrosPlugin - top-level expansion entry point that
// orchestrates the iteration + generation layers.
// Copyright © 2026 Inno Squad. All rights reserved.
//
// `buildCasePathMembers` is the only function called from
// `RoutableMacro` and `CasePathableMacro`. It validates the
// declaration shape (must be a non-generic, non-empty enum),
// extracts cases through the iteration layer, and renders source
// through the generation layer.
//
// The split into three files mirrors the three responsibilities so
// each concern has its own audit surface:
//
//   CasePathEnumIteration.swift   — syntax tree → CasePathEnumCase
//   CasePathMemberGeneration.swift — CasePathEnumCase → source
//   CasePathMemberBuilder.swift    — orchestration + diagnostics
//
// Keeping the file names stable preserves git blame / file-link
// continuity for downstream forks.

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

func buildCasePathMembers(
    macroName: String,
    node: AttributeSyntax,
    declaration: some DeclGroupSyntax,
    context: some MacroExpansionContext
) -> [DeclSyntax] {
    guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
        emitRequiresEnumDiagnostic(
            macroName: macroName,
            node: node,
            declaration: declaration,
            context: context
        )
        return []
    }

    if enumDecl.genericParameterClause != nil {
        emitUnsupportedGenericEnumDiagnostic(
            macroName: macroName,
            node: node,
            enumDecl: enumDecl,
            context: context
        )
        return []
    }

    let cases = extractCasePathEnumCases(from: enumDecl)
    guard !cases.isEmpty else {
        emitEmptyEnumDiagnostic(macroName: macroName, node: node, context: context)
        return []
    }

    let enumName = escapedIdentifier(enumDecl.name)
    let access = inferAccessLevel(from: enumDecl).keyword
    let casesMembers = renderCasePathMembers(
        enumDecl.memberBlock.members,
        enumName: enumName,
        access: access
    )

    let casesEnum: DeclSyntax = """
        \(raw: access) enum Cases {
        \(raw: casesMembers)
        }
        """

    let isMethod: DeclSyntax = """
        \(raw: access) func `is`<Value>(_ casePath: CasePath<Self, Value>) -> Bool {
            casePath.extract(self) != nil
        }
        """

    let subscriptDecl: DeclSyntax = """
        \(raw: access) subscript<Value>(case casePath: CasePath<Self, Value>) -> Value? {
            casePath.extract(self)
        }
        """

    return [casesEnum, isMethod, subscriptDecl]
}

private func renderCasePathMembers(
    _ members: MemberBlockItemListSyntax,
    enumName: String,
    access: String
) -> String {
    members.compactMap { member -> String? in
        if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
            return extractCasePathEnumCases(from: caseDecl, enumName: enumName)
                .map { buildCasePathMember($0, enumName: enumName, access: access) }
                .joined(separator: "\n")
        }
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else { return nil }
        return renderConditionalCasePathMembers(
            conditional,
            enumName: enumName,
            access: access
        )
    }.filter { !$0.isEmpty }.joined(separator: "\n")
}

private func renderConditionalCasePathMembers(
    _ conditional: IfConfigDeclSyntax,
    enumName: String,
    access: String
) -> String? {
    let containsCase = conditional.clauses.contains { clause in
        guard case .decls(let members) = clause.elements else { return false }
        return !extractCasePathEnumCases(from: members, enumName: enumName).isEmpty
    }
    guard containsCase else { return nil }

    var lines: [String] = []
    for clause in conditional.clauses {
        var directive = clause.poundKeyword.text
        if let condition = clause.condition?.trimmedDescription {
            directive += " \(condition)"
        }
        lines.append("    \(directive)")
        guard case .decls(let members) = clause.elements else { continue }
        let body = renderCasePathMembers(members, enumName: enumName, access: access)
        if !body.isEmpty { lines.append(body) }
    }
    lines.append("    \(conditional.poundEndif.text)")
    return lines.joined(separator: "\n")
}
