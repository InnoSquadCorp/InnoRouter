// MARK: - TabItemMacro.swift
// InnoRouterMacrosPlugin - @TabItem implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Marker peer macro consumed by ``RouterMacro``.
///
/// It intentionally emits no peer declarations. Its own role is limited to
/// rejecting invalid attachment sites and a case that is not nested in an
/// `@Router` enum. Metadata parsing and tab witness generation remain owned by
/// `RouterMacro`, which can validate the complete enum in one pass.
public struct TabItemMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumCaseDeclSyntax.self) else {
            diagnoseTabItem(.tabItemRequiresCase, at: node, context: context)
            return []
        }

        guard let nearestEnum = context.lexicalContext.lazy.compactMap({
            $0.as(EnumDeclSyntax.self)
        }).first,
            isRouterEnum(nearestEnum) else {
            diagnoseTabItem(.tabItemRequiresRouter, at: node, context: context)
            return []
        }

        return []
    }
}

private func isRouterEnum(_ enumDecl: EnumDeclSyntax) -> Bool {
    return enumDecl.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attribute.attributeName.trimmedDescription
            .split(separator: ".")
            .last
            .map(String.init) == "Router"
    }
}

func diagnoseTabItem(
    _ message: RouterTabDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: node, message: message))
}
