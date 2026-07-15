// MARK: - RouterMacro.swift
// InnoRouterMacrosPlugin - @Router implementation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implements the macro-first `@Router` expansion.
///
/// The member-attribute role adds `@MainActor` and `@ViewBuilder` to a valid
/// get-only instance `var destination: some View`. The extension role validates
/// the declaration, supplies `DestinationRoute` conformance, and forwards the
/// generated `static destination(for:)` witness to that instance property.
///
/// Diagnostics are emitted only from the extension role so a malformed
/// declaration produces one actionable error instead of one error per member.
/// Constrained generic enums are supported; `Route` conformance lets the Swift
/// type checker diagnose payloads that are not `Hashable` or `Sendable`.
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
            attributes.append(AttributeSyntax(attributeName: qualifiedType(module: "Swift", name: "MainActor")))
        }
        if !hasAttribute(named: "ViewBuilder", on: variable) {
            attributes.append(AttributeSyntax(attributeName: qualifiedType(module: "SwiftUI", name: "ViewBuilder")))
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
        }.filter { conflictsWithGeneratedDestination($0, in: enumDecl) }
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

        let tabExpansion = analyzeRouterTabs(in: enumDecl, context: context)
        if case .invalid = tabExpansion {
            return []
        }
        let deepLinkExpansion = analyzeRouterDeepLinks(
            routerAttribute: node,
            in: enumDecl,
            context: context
        )
        if case .invalid = deepLinkExpansion {
            return []
        }
        return try makeRouterExtensions(
            for: type,
            enumDecl: enumDecl,
            tabExpansion: tabExpansion,
            deepLinkExpansion: deepLinkExpansion,
            node: node,
            context: context
        )
    }
}

private func makeRouterExtensions(
    for type: some TypeSyntaxProtocol,
    enumDecl: EnumDeclSyntax,
    tabExpansion: RouterTabExpansion,
    deepLinkExpansion: RouterDeepLinkExpansion,
    node: AttributeSyntax,
    context: some MacroExpansionContext
) throws -> [ExtensionDeclSyntax] {
    if extractCasePathEnumCases(from: enumDecl).isEmpty {
        diagnose(.emptyRouter, at: node, context: context)
    }

    let hasDestinationRouteConformance = directlyConformsToDestinationRoute(enumDecl)
    if hasDestinationRouteConformance, let inheritanceClause = enumDecl.inheritanceClause {
        diagnose(
            .redundantDestinationRouteConformance,
            at: inheritanceClause,
            context: context
        )
    }
    if directlyConformsToRoute(enumDecl), let inheritanceClause = enumDecl.inheritanceClause {
        diagnose(
            .redundantRouteConformance,
            at: inheritanceClause,
            context: context
        )
    }

    var conformances: [String] = []
    if !hasDestinationRouteConformance {
        conformances.append("InnoRouterSwiftUI.DestinationRoute")
    }

    let access = inferAccessLevel(from: enumDecl).keyword
    let tabMembers: String
    if case .valid(let specification) = tabExpansion {
        if !specification.directlyConformsToRouterTab {
            conformances.append("InnoRouterSwiftUI.RouterTab")
        }
        tabMembers = "\n\n" + renderRouterTabMembers(from: specification, access: access)
    } else {
        tabMembers = ""
    }

    let deepLinkMembers: String
    if case .valid(let specification) = deepLinkExpansion {
        if !specification.directlyConformsToDeepLinkRoute {
            conformances.append("InnoRouterDeepLink.DeepLinkRoute")
        }
        deepLinkMembers = "\n\n" + renderRouterDeepLinkMembers(
            from: specification,
            access: access
        )
    } else {
        deepLinkMembers = ""
    }

    let conformanceClause = conformances.isEmpty
        ? ""
        : ": " + conformances.joined(separator: ", ")
    let extensionDecl = try ExtensionDeclSyntax(
        """
        extension \(type)\(raw: conformanceClause) {
            @Swift.MainActor
            @SwiftUI.ViewBuilder
            \(raw: access) static func destination(for route: Self) -> some SwiftUI.View {
                route.destination
            }\(raw: tabMembers)\(raw: deepLinkMembers)
        }
        """
    )
    return [extensionDecl]
}

private func containsDestinationBinding(_ variable: VariableDeclSyntax) -> Bool {
    variable.bindings.contains { binding in
        binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "destination"
    }
}

private func qualifiedType(module: String, name: String) -> TypeSyntax {
    TypeSyntax(
        MemberTypeSyntax(
            baseType: IdentifierTypeSyntax(name: .identifier(module)),
            period: .periodToken(),
            name: .identifier(name)
        )
    )
}

private func conflictsWithGeneratedDestination(
    _ function: FunctionDeclSyntax,
    in enumDecl: EnumDeclSyntax
) -> Bool {
    guard function.name.text == "destination",
          function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
          function.genericParameterClause == nil else {
        return false
    }

    let parameters = function.signature.parameterClause.parameters
    guard parameters.count == 1,
          let parameter = parameters.first,
          parameter.firstName.text == "for" else {
        return false
    }

    return conflictsWithGeneratedDestinationParameter(parameter.type, in: enumDecl)
}

private func conflictsWithGeneratedDestinationParameter(
    _ type: TypeSyntax,
    in enumDecl: EnumDeclSyntax
) -> Bool {
    if type.trimmedDescription == "Self" {
        return true
    }

    guard let identifier = type.as(IdentifierTypeSyntax.self),
          identifier.name.text == enumDecl.name.text else {
        return false
    }

    guard let arguments = identifier.genericArgumentClause?.arguments else {
        return true
    }

    let parameters = enumDecl.genericParameterClause?.parameters.map(\.name.text) ?? []
    guard arguments.count == parameters.count else {
        return false
    }

    return zip(arguments, parameters).allSatisfy { argument, parameter in
        argument.argument.trimmedDescription == parameter
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

private func directlyConformsToRoute(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.inheritanceClause?.inheritedTypes.contains { inherited in
        inherited.type.trimmedDescription.split(separator: ".").last.map(String.init) == "Route"
    } ?? false
}

private func diagnose(
    _ message: RouterMacroDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: node, message: message))
}
