// MARK: - RouterMacro.swift
// InnoRouterMacrosPlugin - @Router implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct RouterMacro: MemberAttributeMacro, ExtensionMacro {
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
            attributes.append(AttributeSyntax(attributeName: IdentifierTypeSyntax(name: .identifier("MainActor"))))
        }
        if !hasAttribute(named: "ViewBuilder", on: variable) {
            attributes.append(AttributeSyntax(attributeName: IdentifierTypeSyntax(name: .identifier("ViewBuilder"))))
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
                macroName: "Router",
                node: node,
                declaration: declaration,
                context: context
            )
            return []
        }

        let destinationFunctions = enumDecl.memberBlock.members.compactMap {
            $0.decl.as(FunctionDeclSyntax.self)
        }.filter { $0.name.text == "destination" }
        guard destinationFunctions.isEmpty else {
            diagnose(
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
            diagnose(.missingDestination, at: node, context: context)
            return []
        }
        guard destinationVariables.count == 1 else {
            diagnose(
                .invalidDestination(reason: "more than one destination property was found"),
                at: destinationVariables[1],
                context: context
            )
            return []
        }
        if let reason = validateDestination(destination) {
            diagnose(.invalidDestination(reason: reason), at: destination, context: context)
            return []
        }

        if extractCasePathEnumCases(from: enumDecl).isEmpty {
            diagnose(.emptyRouter, at: node, context: context)
        }

        let hasConformance = directlyConformsToDestinationRoute(enumDecl)
        if hasConformance, let inheritanceClause = enumDecl.inheritanceClause {
            diagnose(
                .redundantDestinationRouteConformance,
                at: inheritanceClause,
                context: context
            )
        }

        let access = inferAccessLevel(from: enumDecl).keyword
        let conformance = hasConformance ? "" : ": DestinationRoute"
        let extensionDecl = try ExtensionDeclSyntax(
            """
            extension \(type)\(raw: conformance) {
                @MainActor
                @ViewBuilder
                \(raw: access) static func destination(for route: Self) -> some View {
                    route.destination
                }
            }
            """
        )
        return [extensionDecl]
    }
}

private func containsDestinationBinding(_ variable: VariableDeclSyntax) -> Bool {
    variable.bindings.contains { binding in
        binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "destination"
    }
}

private func validateDestination(_ variable: VariableDeclSyntax) -> String? {
    guard containsDestinationBinding(variable) else {
        return "the property is not named `destination`"
    }
    guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
        return "it must be declared with `var`, not `let`"
    }
    guard !variable.modifiers.contains(where: { modifier in
        modifier.name.tokenKind == .keyword(.static) ||
            modifier.name.tokenKind == .keyword(.class)
    }) else {
        return "it must be an instance property, not a static property"
    }
    guard variable.bindings.count == 1,
          let binding = variable.bindings.first,
          binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "destination" else {
        return "declare `destination` in its own property declaration"
    }
    guard let type = binding.typeAnnotation?.type else {
        return "it needs the explicit return type `some View`"
    }
    let normalizedType = type.trimmedDescription.filter { !$0.isWhitespace }
    guard normalizedType == "someView" || normalizedType == "someSwiftUI.View" else {
        return "its return type must be `some View`"
    }
    guard let accessorBlock = binding.accessorBlock else {
        return "it must be a computed property with a getter"
    }
    switch accessorBlock.accessors {
    case .getter:
        return nil
    case .accessors(let accessors):
        guard accessors.count == 1,
              accessors.first?.accessorSpecifier.tokenKind == .keyword(.get) else {
            return "it must be get-only"
        }
        return nil
    }
}

private func hasAttribute(named expectedName: String, on variable: VariableDeclSyntax) -> Bool {
    variable.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) == expectedName
    }
}

private func directlyConformsToDestinationRoute(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.inheritanceClause?.inheritedTypes.contains { inherited in
        inherited.type.trimmedDescription.split(separator: ".").last.map(String.init) == "DestinationRoute"
    } ?? false
}

private func diagnose(
    _ message: RouterMacroDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: node, message: message))
}
