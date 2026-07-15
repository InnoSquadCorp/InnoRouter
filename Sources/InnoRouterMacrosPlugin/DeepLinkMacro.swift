// MARK: - DeepLinkMacro.swift
// InnoRouterMacrosPlugin - @DeepLink marker implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxMacros

/// Empty peer marker consumed by ``RouterMacro`` after validating its nearest
/// enclosing declaration. Full mapping analysis belongs to the router because
/// duplicate and shadow diagnostics require the complete case set.
public struct DeepLinkMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumCaseDeclSyntax.self) else {
            diagnoseDeepLink(.requiresCase, at: node, context: context)
            return []
        }

        guard let nearestEnum = context.lexicalContext.lazy.compactMap({
            $0.as(EnumDeclSyntax.self)
        }).first,
            isDeepLinkRouterEnum(nearestEnum) else {
            diagnoseDeepLink(.requiresRouter, at: node, context: context)
            return []
        }

        return []
    }
}

private func isDeepLinkRouterEnum(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attribute.attributeName.trimmedDescription
            .split(separator: ".")
            .last
            .map(String.init) == "Router"
    }
}
