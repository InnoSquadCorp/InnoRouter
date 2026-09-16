// MARK: - RouterSceneExpansion.swift
// InnoRouterMacrosPlugin - @Router scene catalog generation
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftSyntax
import SwiftSyntaxMacros

enum RouterSceneExpansion {
    case none
    case invalid
    case valid(RouterSceneSpecification)
}

struct RouterSceneSpecification {
    let items: [RouterSceneItem]
    let directlyConformsToRouterSceneRoute: Bool
}

struct RouterSceneItem {
    let caseName: String
    let id: String
    let styleExpression: String
}

func analyzeRouterScenes(
    in enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) -> RouterSceneExpansion {
    let directCases = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    let annotated = directCases.filter { sceneAttributesForRouter(on: $0).isEmpty == false }

    if let conditionalScene = enumDecl.memberBlock.members.lazy.compactMap({ member -> AttributeSyntax? in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else { return nil }
        return firstSceneAttributeInsideConditional(conditional)
    }).first {
        diagnoseSceneRouter(.conditionalCase, at: conditionalScene, context: context)
        return .invalid
    }

    if let conditionalAttribute = directCases.lazy.compactMap({
        conditionalSceneAttribute(on: $0)
    }).first {
        diagnoseSceneRouter(.conditionalCase, at: conditionalAttribute, context: context)
        return .invalid
    }

    guard !annotated.isEmpty else { return .none }

    var items: [RouterSceneItem] = []
    var ids: Set<String> = []
    for caseDecl in annotated {
        let attributes = sceneAttributesForRouter(on: caseDecl)
        guard attributes.count == 1, let attribute = attributes.first else {
            diagnoseSceneRouter(.duplicateScene, at: attributes[1], context: context)
            return .invalid
        }
        guard caseDecl.elements.count == 1, let element = caseDecl.elements.first else {
            diagnoseSceneRouter(.multipleCasesPerDeclaration, at: caseDecl, context: context)
            return .invalid
        }
        guard !hasSceneAvailabilityAttribute(caseDecl) else {
            diagnoseSceneRouter(
                .unavailableCase(caseName: element.name.text),
                at: caseDecl,
                context: context
            )
            return .invalid
        }
        guard element.parameterClause == nil else {
            diagnoseSceneRouter(
                .associatedValues(caseName: element.name.text),
                at: element,
                context: context
            )
            return .invalid
        }
        guard let parsed = parseRouterSceneAttribute(
            attribute,
            defaultID: element.name.text,
            context: context
        ) else {
            return .invalid
        }
        guard ids.insert(parsed.id).inserted else {
            diagnoseSceneRouter(.duplicateID(parsed.id), at: attribute, context: context)
            return .invalid
        }
        items.append(
            RouterSceneItem(
                caseName: escapedIdentifier(element.name),
                id: parsed.id,
                styleExpression: parsed.styleExpression
            )
        )
    }

    if let conflict = firstRouterGeneratedMemberConflict(
        in: enumDecl.memberBlock.members,
        typeMembers: ["Scene"],
        staticMembers: ["routerScenes"]
    ) {
        diagnoseSceneRouter(
            .generatedMemberConflict(name: conflict.name),
            at: conflict.declaration,
            context: context
        )
        return .invalid
    }

    return .valid(
        RouterSceneSpecification(
            items: items,
            directlyConformsToRouterSceneRoute: directlyConforms(
                enumDecl,
                to: "RouterSceneRoute"
            )
        )
    )
}

func renderRouterSceneMembers(
    from specification: RouterSceneSpecification,
    routeType: String,
    access: String
) -> String {
    let descriptors = specification.items.map { item in
        "        .init(route: .\(item.caseName), id: \(String(reflecting: item.id)), style: \(item.styleExpression))"
    }.joined(separator: ",\n")
    let requests = specification.items.map { item in
        let requestType = item.styleExpression == ".window"
            ? "RouterWindowRequest"
            : "RouterImmersiveSpaceRequest"
        return """
            \(access) static var \(item.caseName): InnoRouterSwiftUI.\(requestType)<\(routeType)> {
                .init(route: .\(item.caseName), sceneID: \(String(reflecting: item.id)))
            }
        """
    }.joined(separator: "\n")
    return """
    \(access) enum Scene {
    \(requests)
    }

    \(access) static var routerScenes: [InnoRouterSwiftUI.RouterSceneDescriptor<Self>] {
        [
    \(descriptors)
        ]
    }
    """
}

private func sceneAttributesForRouter(on caseDecl: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    caseDecl.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              attributeBaseName(attribute) == "Scene" else {
            return nil
        }
        return attribute
    }
}

private func conditionalSceneAttribute(on caseDecl: EnumCaseDeclSyntax) -> AttributeSyntax? {
    caseDecl.attributes.lazy.compactMap { element in
        guard let conditional = element.as(IfConfigDeclSyntax.self) else { return nil }
        return firstConditionalAttribute(named: "Scene", inside: conditional)
    }.first
}

private func firstSceneAttributeInsideConditional(
    _ conditional: IfConfigDeclSyntax
) -> AttributeSyntax? {
    for clause in conditional.clauses {
        guard case .decls(let members) = clause.elements else { continue }
        for member in members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                if let attribute = sceneAttributesForRouter(on: caseDecl).first {
                    return attribute
                }
                if let attribute = conditionalSceneAttribute(on: caseDecl) {
                    return attribute
                }
            }
            if let nestedConditional = member.decl.as(IfConfigDeclSyntax.self),
               let attribute = firstSceneAttributeInsideConditional(nestedConditional) {
                return attribute
            }
        }
    }
    return nil
}

private func hasSceneAvailabilityAttribute(_ caseDecl: EnumCaseDeclSyntax) -> Bool {
    caseDecl.attributes.contains { element in
        if let attribute = element.as(AttributeSyntax.self) {
            return attributeBaseName(attribute) == "available"
        }
        if let conditional = element.as(IfConfigDeclSyntax.self) {
            return firstConditionalAttribute(named: "available", inside: conditional) != nil
        }
        return false
    }
}

private func parseRouterSceneAttribute(
    _ attribute: AttributeSyntax,
    defaultID: String,
    context: some MacroExpansionContext
) -> (id: String, styleExpression: String)? {
    guard case .argumentList(let arguments) = attribute.arguments,
          let styleArgument = arguments.first,
          styleArgument.label == nil,
          arguments.count == 1 || arguments.count == 2 else {
        diagnoseSceneRouter(
            .invalidArguments(reason: "use `.window` or `.immersiveSpace` plus an optional `id:` literal"),
            at: attribute,
            context: context
        )
        return nil
    }
    let styleName = styleArgument.expression.as(MemberAccessExprSyntax.self)?
        .declName.baseName.text
    let styleExpression: String
    switch styleName {
    case "window":
        styleExpression = ".window"
    case "immersiveSpace":
        styleExpression = ".immersiveSpace"
    default:
        diagnoseSceneRouter(
            .invalidArguments(reason: "the style must be `.window` or `.immersiveSpace`"),
            at: styleArgument.expression,
            context: context
        )
        return nil
    }

    guard arguments.count == 2 else {
        return (defaultID, styleExpression)
    }
    guard let idArgument = arguments.last,
          idArgument.label?.text == "id",
          let literal = idArgument.expression.as(StringLiteralExprSyntax.self),
          let id = literal.representedLiteralValue,
          id.contains(where: { !$0.isWhitespace }) else {
        diagnoseSceneRouter(
            .invalidArguments(reason: "`id` must be one nonempty noninterpolated string literal"),
            at: attribute,
            context: context
        )
        return nil
    }
    return (id, styleExpression)
}
