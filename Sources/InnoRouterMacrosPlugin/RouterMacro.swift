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
        let sceneExpansion = analyzeRouterScenes(in: enumDecl, context: context)
        if case .invalid = sceneExpansion {
            return []
        }
        // One parent type context for every helper. A generic router nested in
        // another type is spelled without its arguments here, so any helper
        // that skips the specialization emits `Parent.Router` where the
        // compiler requires `Parent.Router<Value>`.
        let parentRouteType = specializedRouterType(
            type.trimmedDescription,
            for: enumDecl
        )
        let presentationResultExpansion = analyzeRouterPresentationResults(
            in: enumDecl,
            routeType: parentRouteType,
            context: context
        )
        if case .invalid = presentationResultExpansion {
            return []
        }
        let featureRouteType = parentRouteType
        let featureExpansion = analyzeRouterFeatures(
            in: enumDecl,
            routeType: featureRouteType,
            context: context
        )
        if case .invalid = featureExpansion {
            return []
        }
        let deepLinkExpansion = analyzeRouterDeepLinks(
            routerAttribute: node,
            in: enumDecl,
            featureCaseCount: {
                if case .valid(let specification) = featureExpansion {
                    return specification.items.count
                }
                return 0
            }(),
            context: context
        )
        if case .invalid = deepLinkExpansion {
            return []
        }
        return try makeRouterExtensions(
            for: type,
            enumDecl: enumDecl,
            tabExpansion: tabExpansion,
            sceneExpansion: sceneExpansion,
            presentationResultExpansion: presentationResultExpansion,
            featureExpansion: featureExpansion,
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
    sceneExpansion: RouterSceneExpansion,
    presentationResultExpansion: RouterPresentationResultExpansion,
    featureExpansion: RouterFeatureExpansion,
    deepLinkExpansion: RouterDeepLinkExpansion,
    node: AttributeSyntax,
    context: some MacroExpansionContext
) throws -> [ExtensionDeclSyntax] {
    let specializedType = specializedRouterType(type.trimmedDescription, for: enumDecl)
    if extractCasePathEnumCases(from: enumDecl).isEmpty {
        diagnose(.emptyRouter, at: node, context: context)
    }

    let hasDestinationRouteConformance = directlyConformsToDestinationRoute(enumDecl)
    diagnoseRedundantConformances(
        in: enumDecl,
        hasDestinationRouteConformance: hasDestinationRouteConformance,
        context: context
    )

    var conformances: [String] = []
    if !hasDestinationRouteConformance {
        conformances.append("InnoRouterSwiftUI.DestinationRoute")
    }

    let access = inferAccessLevel(from: enumDecl).keyword
    let tabMembers: String
    if case .valid(let specification) = tabExpansion {
        if !specification.directlyConformsToRouterTabRoute {
            conformances.append("InnoRouterSwiftUI.RouterTabRoute")
        }
        tabMembers = "\n\n" + renderRouterTabMembers(from: specification, access: access)
    } else {
        tabMembers = ""
    }

    let featureSpecification: RouterFeatureSpecification? = if case .valid(let specification) = featureExpansion {
        specification
    } else {
        nil
    }
    let deepLinkMembers: String
    if case .valid(let specification) = deepLinkExpansion {
        if !specification.directlyConformsToDeepLinkRoute {
            conformances.append("InnoRouterDeepLink.DeepLinkRoute")
        }
        deepLinkMembers = "\n\n" + renderRouterDeepLinkMembers(
            from: specification,
            access: access,
            declarationNamespace: type.trimmedDescription,
            features: featureSpecification
        )
    } else {
        deepLinkMembers = ""
    }

    let sceneMembers: String
    if case .valid(let specification) = sceneExpansion {
        if !specification.directlyConformsToRouterSceneRoute {
            conformances.append("InnoRouterSwiftUI.RouterSceneRoute")
        }
        sceneMembers = "\n\n" + renderRouterSceneMembers(
            from: specification,
            routeType: specializedType,
            access: access
        )
    } else {
        sceneMembers = ""
    }

    let presentationResultMembers: String
    if case .valid(let items) = presentationResultExpansion {
        presentationResultMembers = "\n\n" + renderRouterPresentationResultMembers(
            from: items,
            routeType: specializedType,
            access: access
        )
    } else {
        presentationResultMembers = ""
    }

    let featureMembers: String
    if case .valid(let specification) = featureExpansion {
        featureMembers = "\n\n" + renderRouterFeatureMembers(
            from: specification,
            parentType: specializedType,
            access: access
        )
    } else {
        featureMembers = ""
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
            }\(raw: tabMembers)\(raw: sceneMembers)\(raw: featureMembers)\(raw: presentationResultMembers)\(raw: deepLinkMembers)
        }
        """
    )
    return [extensionDecl]
}

func containsDestinationBinding(_ variable: VariableDeclSyntax) -> Bool {
    variable.bindings.contains { binding in
        binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "destination"
    }
}

func qualifiedType(module: String, name: String) -> TypeSyntax {
    TypeSyntax(
        MemberTypeSyntax(
            baseType: IdentifierTypeSyntax(name: .identifier(module)),
            period: .periodToken(),
            name: .identifier(name)
        )
    )
}

private func specializedRouterType(
    _ type: String,
    for enumDecl: EnumDeclSyntax
) -> String {
    guard let parameters = enumDecl.genericParameterClause?.parameters,
          !parameters.isEmpty else {
        return type
    }
    let finalComponent = type.split(separator: ".").last.map(String.init) ?? type
    guard !finalComponent.contains("<") else { return type }
    let arguments = parameters.map { parameter in
        if parameter.specifier?.tokenKind == .keyword(.each) {
            return "repeat each \(parameter.name.text)"
        }
        return parameter.name.text
    }
    return "\(type)<\(arguments.joined(separator: ", "))>"
}

func conflictsWithGeneratedDestination(
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

func conflictsWithGeneratedDestinationParameter(
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

func validateDestination(_ variable: VariableDeclSyntax) -> String? {
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

func hasAttribute(named expectedName: String, on variable: VariableDeclSyntax) -> Bool {
    variable.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) == expectedName
    }
}

func directlyConformsToDestinationRoute(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.inheritanceClause?.inheritedTypes.contains { inherited in
        inherited.type.trimmedDescription.split(separator: ".").last.map(String.init) == "DestinationRoute"
    } ?? false
}

func directlyConformsToRoute(_ enumDecl: EnumDeclSyntax) -> Bool {
    enumDecl.inheritanceClause?.inheritedTypes.contains { inherited in
        inherited.type.trimmedDescription.split(separator: ".").last.map(String.init) == "Route"
    } ?? false
}

/// Warns about `Route` / `DestinationRoute` conformances that `@Router`
/// already supplies, offering the removal edit for each.
private func diagnoseRedundantConformances(
    in enumDecl: EnumDeclSyntax,
    hasDestinationRouteConformance: Bool,
    context: some MacroExpansionContext
) {
    guard let inheritanceClause = enumDecl.inheritanceClause else { return }

    func report(_ message: RouterMacroDiagnostic, removing conformanceName: String) {
        diagnose(
            message,
            at: inheritanceClause,
            context: context,
            fixIts: [
                removeConformanceFixIt(
                    named: conformanceName,
                    from: inheritanceClause,
                    in: enumDecl
                ),
            ].compactMap { $0 }
        )
    }

    if hasDestinationRouteConformance {
        report(.redundantDestinationRouteConformance, removing: "DestinationRoute")
    }
    if directlyConformsToRoute(enumDecl) {
        report(.redundantRouteConformance, removing: "Route")
    }
}

private func diagnose(
    _ message: RouterMacroDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext,
    fixIts: [FixIt] = []
) {
    context.diagnose(Diagnostic(node: node, message: message, fixIts: fixIts))
}
