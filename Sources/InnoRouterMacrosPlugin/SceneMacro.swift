// MARK: - SceneMacro.swift
// InnoRouterMacrosPlugin - @Scene marker implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Empty peer marker consumed by ``RouterMacro`` after validating the
/// complete enum inventory.
public struct SceneMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumCaseDeclSyntax.self) else {
            diagnoseSceneRouter(.sceneRequiresCase, at: node, context: context)
            return []
        }

        guard let nearestEnum = context.lexicalContext.lazy.compactMap({
            $0.as(EnumDeclSyntax.self)
        }).first,
            hasRouterAttribute(nearestEnum) else {
            diagnoseSceneRouter(.sceneRequiresRouter, at: node, context: context)
            return []
        }

        return []
    }
}

private func hasRouterAttribute(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attributeBaseName(attribute) == "Router"
    }
}

func diagnoseSceneRouter(
    _ message: SceneRouterDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext,
    fixIts: [FixIt] = []
) {
    context.diagnose(Diagnostic(node: node, message: message, fixIts: fixIts))
}
