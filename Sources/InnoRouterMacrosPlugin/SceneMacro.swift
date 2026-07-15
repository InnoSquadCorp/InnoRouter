// MARK: - SceneMacro.swift
// InnoRouterMacrosPlugin - @Scene marker implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Empty peer marker consumed by ``SceneRouterMacro`` after validating the
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
            hasSceneRouterAttribute(nearestEnum) else {
            diagnoseSceneRouter(.sceneRequiresSceneRouter, at: node, context: context)
            return []
        }

        return []
    }
}

func diagnoseSceneRouter(
    _ message: SceneRouterDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: node, message: message))
}
