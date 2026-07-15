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
