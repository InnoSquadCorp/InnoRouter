import SwiftSyntax
import SwiftSyntaxMacros

enum RouterFeatureExpansion {
    case none
    case invalid
    case valid(RouterFeatureSpecification)
}

struct RouterFeatureSpecification {
    let items: [RouterFeatureItem]
}

struct RouterFeatureItem {
    let caseName: String
    let childType: String
    let emittedLabel: String?
    let id: String
}

func analyzeRouterFeatures(
    in enumDecl: EnumDeclSyntax,
    routeType: String,
    context: some MacroExpansionContext
) -> RouterFeatureExpansion {
    let directCases = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    if let markedConditional = enumDecl.memberBlock.members.lazy.compactMap({
        member -> AttributeSyntax? in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else { return nil }
        return firstFeatureAttributeInsideConditional(conditional)
    }).first {
        diagnoseFeature(.conditionalCase, at: markedConditional, context: context)
        return .invalid
    }

    if let conditionalAttribute = directCases.lazy.compactMap({ declaration in
        declaration.attributes.lazy.compactMap { element -> AttributeSyntax? in
            guard let conditional = element.as(IfConfigDeclSyntax.self) else { return nil }
            return firstConditionalAttribute(named: "FeatureRoute", inside: conditional)
        }.first
    }).first {
        diagnoseFeature(.conditionalCase, at: conditionalAttribute, context: context)
        return .invalid
    }

    let marked = directCases.filter { featureAttributes(on: $0).isEmpty == false }
    guard marked.isEmpty == false else { return .none }

    if let conflict = firstRouterFeatureMemberConflict(in: enumDecl.memberBlock.members) {
        diagnoseFeature(
            .conflictingMember(conflict.name),
            at: conflict.declaration,
            context: context
        )
        return .invalid
    }

    var ids: Set<String> = []
    var items: [RouterFeatureItem] = []
    for declaration in marked {
        let attributes = featureAttributes(on: declaration)
        guard attributes.count == 1, let attribute = attributes.first else {
            diagnoseFeature(.duplicateAttribute, at: attributes[1], context: context)
            return .invalid
        }
        guard declaration.elements.count == 1, let element = declaration.elements.first else {
            diagnoseFeature(.multipleCases, at: declaration, context: context)
            return .invalid
        }
        let name = escapedIdentifier(element.name)
        guard let parameters = element.parameterClause?.parameters,
              parameters.count == 1,
              let parameter = parameters.first else {
            diagnoseFeature(.invalidPayload(caseName: name), at: element, context: context)
            return .invalid
        }
        guard declaration.attributes.contains(where: { value in
            guard let attribute = value.as(AttributeSyntax.self) else { return false }
            return attributeBaseName(attribute) == "available"
        }) == false else {
            diagnoseFeature(.unavailableCase(name), at: declaration, context: context)
            return .invalid
        }
        guard let id = parseFeatureID(attribute, default: element.name.text) else {
            diagnoseFeature(.invalidID, at: attribute, context: context)
            return .invalid
        }
        guard ids.insert(id).inserted else {
            diagnoseFeature(.duplicateID(id), at: attribute, context: context)
            return .invalid
        }
        items.append(
            RouterFeatureItem(
                caseName: name,
                childType: routerFeaturePayloadType(
                    parameter.type,
                    routeType: routeType
                ),
                emittedLabel: emittedLabel(for: parameter),
                id: id
            )
        )
    }
    return .valid(RouterFeatureSpecification(items: items))
}

private struct RouterFeatureMemberConflict {
    let name: String
    let declaration: DeclSyntax
}

private func firstRouterFeatureMemberConflict(
    in members: MemberBlockItemListSyntax
) -> RouterFeatureMemberConflict? {
    guard let conflict = firstRouterGeneratedMemberConflict(
        in: members,
        typeMembers: ["Feature"],
        staticMembers: ["routerFeatureCatalog"],
        parameterlessCases: ["routerFeatureCatalog"]
    ) else {
        return nil
    }
    return .init(name: conflict.name, declaration: conflict.declaration)
}

private final class RouterFeatureSelfTypeRewriter: SyntaxRewriter {
    private let routeType: TypeSyntax

    init(routeType: String) {
        self.routeType = TypeSyntax(stringLiteral: routeType)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
        guard node.name.tokenKind == .keyword(.Self),
              node.genericArgumentClause == nil else {
            return super.visit(node)
        }
        return routeType
    }
}

private func routerFeaturePayloadType(_ type: TypeSyntax, routeType: String) -> String {
    RouterFeatureSelfTypeRewriter(routeType: routeType)
        .rewrite(Syntax(type))
        .trimmedDescription
}

func renderRouterFeatureMembers(
    from specification: RouterFeatureSpecification,
    parentType: String,
    access: String
) -> String {
    let members = specification.items.map { item in
        let embed = item.emittedLabel.map { ".\(item.caseName)(\($0): value)" }
            ?? ".\(item.caseName)(value)"
        return """
        \(access) static var \(item.caseName): InnoRouterCore.RouterFeatureMapping<\(parentType), \(item.childType)> {
            .init(
                id: \(swiftStringLiteral(item.id)),
                namespace: \(swiftStringLiteral(parentType + "." + item.id)),
                route: .init(
                    embed: { value in
                        \(embed)
                    },
                    extract: { parent in
                        guard case .\(item.caseName)(let value) = parent else {
                            return nil
                        }
                        return value
                    }
                )
            )
        }
        """
    }.joined(separator: "\n\n")

    let catalogEntries = specification.items.map { item in
        """
        .init(
            id: \(swiftStringLiteral(item.id)),
            namespace: \(swiftStringLiteral(parentType + "." + item.id)),
            childRouteTypeName: \(swiftStringLiteral(item.childType))
        )
        """
    }.joined(separator: ",\n")
    let catalogMember = """
    \(access) static var routerFeatureCatalog: [InnoRouterCore.RouterFeatureCatalogEntry] {
        [
    \(indentEveryLine(catalogEntries, by: 8))
        ]
    }
    """

    return """
    \(access) enum Feature {
    \(indentEveryLine(members, by: 4))
    }

    \(catalogMember)
    """
}

private func featureAttributes(on declaration: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    declaration.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              attributeBaseName(attribute) == "FeatureRoute" else { return nil }
        return attribute
    }
}

private func firstFeatureAttributeInsideConditional(
    _ conditional: IfConfigDeclSyntax
) -> AttributeSyntax? {
    for clause in conditional.clauses {
        guard case .decls(let members) = clause.elements else { continue }
        for member in members {
            if let caseDeclaration = member.decl.as(EnumCaseDeclSyntax.self) {
                if let attribute = featureAttributes(on: caseDeclaration).first {
                    return attribute
                }
                if let attribute = caseDeclaration.attributes.lazy.compactMap({
                    element -> AttributeSyntax? in
                    guard let conditional = element.as(IfConfigDeclSyntax.self) else { return nil }
                    return firstConditionalAttribute(named: "FeatureRoute", inside: conditional)
                }).first {
                    return attribute
                }
            }
            if let nested = member.decl.as(IfConfigDeclSyntax.self),
               let attribute = firstFeatureAttributeInsideConditional(nested) {
                return attribute
            }
        }
    }
    return nil
}

private func parseFeatureID(_ attribute: AttributeSyntax, default defaultID: String) -> String? {
    guard let arguments = attribute.arguments else { return defaultID }
    guard case .argumentList(let list) = arguments else { return nil }
    guard list.count == 1, let argument = list.first, argument.label == nil,
          let literal = argument.expression.as(StringLiteralExprSyntax.self),
          literal.segments.count == 1,
          case .stringSegment(let segment) = literal.segments.first,
          segment.content.text.isEmpty == false else { return nil }
    return segment.content.text
}
