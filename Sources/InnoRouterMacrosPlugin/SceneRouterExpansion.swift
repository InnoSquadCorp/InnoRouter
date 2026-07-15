// MARK: - SceneRouterExpansion.swift
// InnoRouterMacrosPlugin - @SceneRouter inventory analysis
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

enum SceneRouterExpansion {
    case invalid
    case valid(SceneRouterSpecification)
}

struct SceneRouterSpecification {
    let items: [SceneRouterItem]
}

struct SceneRouterItem {
    let caseName: String
    let id: String
    let style: SceneRouterStyle
    let attribute: AttributeSyntax
}

enum SceneRouterStyle: Equatable {
    case window
    case volumetric(width: Double, height: Double, depth: Double)
    case immersive(style: String)
}

func analyzeSceneRouter(
    in enumDecl: EnumDeclSyntax,
    context: some MacroExpansionContext
) -> SceneRouterExpansion {
    if hasAttribute(named: "Router", on: enumDecl) {
        diagnoseSceneRouter(.conflictsWithRouter, at: enumDecl, context: context)
        return .invalid
    }
    if enumDecl.genericParameterClause != nil {
        diagnoseSceneRouter(.unsupportedGenericRouter, at: enumDecl, context: context)
        return .invalid
    }

    let directCases = enumDecl.memberBlock.members.compactMap {
        $0.decl.as(EnumCaseDeclSyntax.self)
    }
    let conditionalCases = enumDecl.memberBlock.members.flatMap { member in
        guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else {
            return [EnumCaseDeclSyntax]()
        }
        return sceneCasesInsideConditional(conditional)
    }
    if let conditionalCase = conditionalCases.first {
        diagnoseSceneRouter(.conditionalCase, at: conditionalCase, context: context)
        return .invalid
    }
    guard !directCases.isEmpty else {
        diagnoseSceneRouter(.emptyRouter, at: enumDecl, context: context)
        return .invalid
    }

    var items: [SceneRouterItem] = []
    var ids: Set<String> = []
    for caseDecl in directCases {
        guard let item = analyzeSceneCase(caseDecl, context: context) else {
            return .invalid
        }
        guard ids.insert(item.id).inserted else {
            diagnoseSceneRouter(.duplicateID(item.id), at: item.attribute, context: context)
            return .invalid
        }
        items.append(item)
    }
    return .valid(SceneRouterSpecification(items: items))
}

func hasSceneRouterAttribute(_ enumDecl: EnumDeclSyntax) -> Bool {
    hasAttribute(named: "SceneRouter", on: enumDecl)
}

private func analyzeSceneCase(
    _ caseDecl: EnumCaseDeclSyntax,
    context: some MacroExpansionContext
) -> SceneRouterItem? {
    guard caseDecl.elements.count == 1, let element = caseDecl.elements.first else {
        diagnoseSceneRouter(.multipleCasesPerDeclaration, at: caseDecl, context: context)
        return nil
    }
    let caseName = element.name.text
    if caseDecl.attributes.contains(where: { $0.is(IfConfigDeclSyntax.self) }) {
        diagnoseSceneRouter(
            .conditionalAttributes(caseName: caseName),
            at: caseDecl,
            context: context
        )
        return nil
    }
    if hasAttribute(named: "available", on: caseDecl) {
        diagnoseSceneRouter(
            .unavailableCase(caseName: caseName),
            at: caseDecl,
            context: context
        )
        return nil
    }

    let attributes = sceneAttributes(on: caseDecl)
    guard let attribute = attributes.first else {
        diagnoseSceneRouter(.missingScene(caseName: caseName), at: caseDecl, context: context)
        return nil
    }
    guard attributes.count == 1 else {
        diagnoseSceneRouter(.duplicateScene, at: attributes[1], context: context)
        return nil
    }
    guard element.parameterClause == nil else {
        diagnoseSceneRouter(
            .associatedValues(caseName: caseName),
            at: element,
            context: context
        )
        return nil
    }

    switch parseSceneAttribute(attribute, defaultID: caseName) {
    case .success(let parsed):
        return SceneRouterItem(
            caseName: escapedIdentifier(element.name),
            id: parsed.id,
            style: parsed.style,
            attribute: attribute
        )
    case .failure(let failure):
        switch failure {
        case .arguments(let reason):
            diagnoseSceneRouter(.invalidArguments(reason: reason), at: attribute, context: context)
        case .size(let reason):
            diagnoseSceneRouter(.invalidSize(reason: reason), at: attribute, context: context)
        }
        return nil
    }
}

private struct ParsedSceneAttribute {
    let id: String
    let style: SceneRouterStyle
}

private enum SceneAttributeFailure: Error {
    case arguments(String)
    case size(String)
}

private func parseSceneAttribute(
    _ attribute: AttributeSyntax,
    defaultID: String
) -> Result<ParsedSceneAttribute, SceneAttributeFailure> {
    guard case .argumentList(let arguments) = attribute.arguments,
          let styleArgument = arguments.first,
          styleArgument.label == nil else {
        return .failure(.arguments("provide one scene style as the first unlabeled argument"))
    }
    guard arguments.count == 1 || arguments.count == 2 else {
        return .failure(.arguments("use only the scene style and optional `id:` literal"))
    }

    let id: String
    if arguments.count == 2 {
        guard let idArgument = arguments.last,
              idArgument.label?.text == "id",
              let literal = nonemptyPlainString(idArgument.expression) else {
            return .failure(.arguments("`id` must be one nonempty plain string literal"))
        }
        id = literal
    } else {
        id = defaultID
    }

    switch parseSceneStyle(styleArgument.expression) {
    case .success(let style):
        return .success(ParsedSceneAttribute(id: id, style: style))
    case .failure(let failure):
        return .failure(failure)
    }
}

private func parseSceneStyle(
    _ expression: ExprSyntax
) -> Result<SceneRouterStyle, SceneAttributeFailure> {
    if sceneStyleName(expression) == "window" {
        return .success(.window)
    }
    guard let call = expression.as(FunctionCallExprSyntax.self),
          let name = sceneStyleName(call.calledExpression) else {
        return .failure(
            .arguments("use `.window`, `.volumetric(width:height:depth:)`, or `.immersive(style:)`")
        )
    }

    switch name {
    case "volumetric":
        return parseVolumetricStyle(call)
    case "immersive":
        return parseImmersiveStyle(call)
    default:
        return .failure(
            .arguments("use `.window`, `.volumetric(width:height:depth:)`, or `.immersive(style:)`")
        )
    }
}

private func parseVolumetricStyle(
    _ call: FunctionCallExprSyntax
) -> Result<SceneRouterStyle, SceneAttributeFailure> {
    let expectedLabels = ["width", "height", "depth"]
    guard call.arguments.count == expectedLabels.count,
          zip(call.arguments, expectedLabels).allSatisfy({ argument, label in
              argument.label?.text == label
          }) else {
        return .failure(.arguments("volumetric scenes require `width:`, `height:`, and `depth:`"))
    }

    let values = call.arguments.map { numericLiteral($0.expression) }
    guard values.allSatisfy({ $0 != nil }) else {
        return .failure(.size("dimensions must be plain finite numeric literals"))
    }
    let dimensions = values.compactMap { $0 }
    guard dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        return .failure(.size("every dimension must be finite and greater than zero"))
    }
    return .success(
        .volumetric(
            width: dimensions[0],
            height: dimensions[1],
            depth: dimensions[2]
        )
    )
}

private func parseImmersiveStyle(
    _ call: FunctionCallExprSyntax
) -> Result<SceneRouterStyle, SceneAttributeFailure> {
    guard call.arguments.count == 1,
          let argument = call.arguments.first,
          argument.label?.text == "style",
          let style = sceneStyleName(argument.expression),
          ["mixed", "progressive", "full"].contains(style) else {
        return .failure(.arguments("immersive scenes require `style: .mixed`, `.progressive`, or `.full`"))
    }
    return .success(.immersive(style: style))
}

private func sceneStyleName(_ expression: ExprSyntax) -> String? {
    if let member = expression.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text
    }
    return nil
}

private func numericLiteral(_ expression: ExprSyntax) -> Double? {
    let source = expression.trimmedDescription.replacingOccurrences(of: "_", with: "")
    return Double(source)
}

private func nonemptyPlainString(_ expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
          literal.segments.count == 1,
          let segment = literal.segments.first?.as(StringSegmentSyntax.self),
          segment.content.text.contains(where: { !$0.isWhitespace }) else {
        return nil
    }
    return segment.content.text
}

private func sceneAttributes(on caseDecl: EnumCaseDeclSyntax) -> [AttributeSyntax] {
    caseDecl.attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self),
              attributeBaseName(attribute) == "Scene" else {
            return nil
        }
        return attribute
    }
}

private func sceneCasesInsideConditional(
    _ conditional: IfConfigDeclSyntax
) -> [EnumCaseDeclSyntax] {
    conditional.clauses.flatMap { clause in
        guard case .decls(let members) = clause.elements else {
            return [EnumCaseDeclSyntax]()
        }
        return members.flatMap { member in
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                return [caseDecl]
            }
            if let nested = member.decl.as(IfConfigDeclSyntax.self) {
                return sceneCasesInsideConditional(nested)
            }
            return []
        }
    }
}

private func hasAttribute(
    named expectedName: String,
    on declaration: EnumDeclSyntax
) -> Bool {
    declaration.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attributeBaseName(attribute) == expectedName
    }
}

private func hasAttribute(
    named expectedName: String,
    on declaration: EnumCaseDeclSyntax
) -> Bool {
    declaration.attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attributeBaseName(attribute) == expectedName
    }
}
