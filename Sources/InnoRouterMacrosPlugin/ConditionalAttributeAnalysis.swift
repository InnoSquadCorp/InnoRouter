// MARK: - ConditionalAttributeAnalysis.swift
// InnoRouterMacrosPlugin - shared conditional attribute inspection
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftSyntax

func attributeBaseName(_ attribute: AttributeSyntax) -> String? {
    attribute.attributeName.trimmedDescription
        .split(separator: ".")
        .last
        .map(String.init)
}

func firstConditionalAttribute(
    named name: String,
    inside conditional: IfConfigDeclSyntax
) -> AttributeSyntax? {
    for clause in conditional.clauses {
        guard case .attributes(let attributes) = clause.elements else { continue }
        for element in attributes {
            if let attribute = element.as(AttributeSyntax.self),
               attributeBaseName(attribute) == name {
                return attribute
            }
            if let nestedConditional = element.as(IfConfigDeclSyntax.self),
               let attribute = firstConditionalAttribute(named: name, inside: nestedConditional) {
                return attribute
            }
        }
    }
    return nil
}

func firstConditionalEnumCaseAttribute(
    named name: String,
    inside conditional: IfConfigDeclSyntax
) -> AttributeSyntax? {
    for clause in conditional.clauses {
        guard case .decls(let members) = clause.elements else { continue }
        for member in members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
               let attribute = caseDecl.attributes.lazy.compactMap({ element -> AttributeSyntax? in
                   guard let attribute = element.as(AttributeSyntax.self),
                         attributeBaseName(attribute) == name else { return nil }
                   return attribute
               }).first {
                return attribute
            }
            if let nested = member.decl.as(IfConfigDeclSyntax.self),
               let attribute = firstConditionalEnumCaseAttribute(named: name, inside: nested) {
                return attribute
            }
        }
    }
    return nil
}
