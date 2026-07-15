// MARK: - SceneRouterMacro.swift
// InnoRouterMacrosPlugin - @SceneRouter implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Validates one stable app-scene inventory and supplies its route destination
/// conformance. Scene host generation is intentionally layered on this same
/// analyzed specification so invalid declarations fail before runtime code is
/// emitted.
public struct SceneRouterMacro: MemberAttributeMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard declaration.is(EnumDeclSyntax.self),
              let variable = member.as(VariableDeclSyntax.self),
              validateDestination(variable) == nil else {
            return []
        }

        var attributes: [AttributeSyntax] = []
        if !hasAttribute(named: "MainActor", on: variable) {
            attributes.append(
                AttributeSyntax(
                    attributeName: qualifiedType(module: "Swift", name: "MainActor")
                )
            )
        }
        if !hasAttribute(named: "ViewBuilder", on: variable) {
            attributes.append(
                AttributeSyntax(
                    attributeName: qualifiedType(module: "SwiftUI", name: "ViewBuilder")
                )
            )
        }
        return attributes
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            emitRequiresEnumDiagnostic(
                macroName: "SceneRouter",
                node: node,
                declaration: declaration,
                context: context
            )
            return []
        }
        guard case .valid = analyzeSceneRouter(in: enumDecl, context: context) else {
            return []
        }

        let destinationFunctions = enumDecl.memberBlock.members.compactMap {
            $0.decl.as(FunctionDeclSyntax.self)
        }.filter { conflictsWithGeneratedDestination($0, in: enumDecl) }
        guard destinationFunctions.isEmpty else {
            diagnoseSceneRouter(
                .conflictingDestination,
                at: destinationFunctions[0],
                context: context
            )
            return []
        }

        let destinationVariables = enumDecl.memberBlock.members.compactMap {
            $0.decl.as(VariableDeclSyntax.self)
        }.filter(containsDestinationBinding)
        guard let destination = destinationVariables.first else {
            diagnoseSceneRouter(.missingDestination, at: node, context: context)
            return []
        }
        guard destinationVariables.count == 1 else {
            diagnoseSceneRouter(
                .invalidDestination(reason: "more than one destination property was found"),
                at: destinationVariables[1],
                context: context
            )
            return []
        }
        if let reason = validateDestination(destination) {
            diagnoseSceneRouter(
                .invalidDestination(reason: reason),
                at: destination,
                context: context
            )
            return []
        }

        let directlyConformsToDestination = directlyConformsToDestinationRoute(enumDecl)
        if directlyConformsToDestination, let inheritanceClause = enumDecl.inheritanceClause {
            diagnoseSceneRouter(
                .redundantDestinationRouteConformance,
                at: inheritanceClause,
                context: context
            )
        }
        if directlyConformsToRoute(enumDecl), let inheritanceClause = enumDecl.inheritanceClause {
            diagnoseSceneRouter(
                .redundantRouteConformance,
                at: inheritanceClause,
                context: context
            )
        }

        let conformance = directlyConformsToDestination
            ? ""
            : ": InnoRouterSwiftUI.DestinationRoute"
        let access = inferAccessLevel(from: enumDecl).keyword
        return [
            try ExtensionDeclSyntax(
                """
                extension \(type)\(raw: conformance) {
                    @Swift.MainActor
                    @SwiftUI.ViewBuilder
                    \(raw: access) static func destination(for route: Self) -> some SwiftUI.View {
                        route.destination
                    }
                }
                """
            )
        ]
    }
}
