// MARK: - SceneRouterSceneGeneration.swift
// InnoRouterMacrosPlugin - generated visionOS scene composition
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftSyntax

struct SceneRouterGeneratedMemberConflict {
    let name: String
    let node: Syntax
}

func sceneRouterGeneratedMemberConflict(
    in enumDecl: EnumDeclSyntax
) -> SceneRouterGeneratedMemberConflict? {
    for member in enumDecl.memberBlock.members {
        if let conflict = sceneRouterGeneratedMemberConflict(in: member.decl) {
            return conflict
        }
    }
    return nil
}

func renderSceneRouterSceneMembers(
    specification: SceneRouterSpecification,
    routeType: String,
    access: String
) -> String {
    let registryItems = specification.items
        .map(renderSceneRouterRegistryItem)
        .joined(separator: ",\n")
    let immersionStates = specification.items.enumerated().compactMap { index, item in
        guard case .immersive(let style) = item.style else { return nil }
        return """
        @SwiftUI.State
        private var _innoRouterImmersionStyle\(index): any SwiftUI.ImmersionStyle =
            \(renderSwiftUIImmersionStyle(style))
        """
    }.joined(separator: "\n\n")
    let scenes = specification.items.enumerated().map { index, item in
        renderSceneRouterScene(
            item,
            index: index,
            routeType: routeType
        )
    }.joined(separator: "\n\n")

    let stateMembers = immersionStates.isEmpty
        ? """
        @SwiftUI.State
        private var _innoRouterStore = InnoRouterSpatial.SceneStore<\(routeType)>()
        """
        : """
        @SwiftUI.State
        private var _innoRouterStore = InnoRouterSpatial.SceneStore<\(routeType)>()

        \(immersionStates)
        """

    return """
    #if os(visionOS)
    @Swift.MainActor
    \(access) static var scenes: some SwiftUI.Scene {
        _InnoRouterSceneContainer()
    }

    @Swift.MainActor
    private struct _InnoRouterSceneContainer: SwiftUI.Scene {
    \(indentSceneRouterSource(stateMembers, by: 4))

        private let _innoRouterScenes = InnoRouterSpatial.SceneRegistry<\(routeType)>(
    \(indentSceneRouterSource(registryItems, by: 8))
        )

        @SwiftUI.SceneBuilder
        var body: some SwiftUI.Scene {
    \(indentSceneRouterSource(scenes, by: 8))
        }
    }
    #endif
    """
}

func sceneRouterStringLiteral(_ value: String) -> String {
    var literal = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x09: literal += "\\t"
        case 0x0A: literal += "\\n"
        case 0x0D: literal += "\\r"
        case 0x22: literal += "\\\""
        case 0x5C: literal += "\\\\"
        case 0x00 ... 0x1F, 0x7F:
            literal += "\\u{\(String(scalar.value, radix: 16))}"
        default:
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                literal += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                literal.unicodeScalars.append(scalar)
            }
        }
    }
    literal += "\""
    return literal
}

private func sceneRouterDeclaredTypeName(_ declaration: DeclSyntax) -> String? {
    if let value = declaration.as(StructDeclSyntax.self) { return value.name.text }
    if let value = declaration.as(ClassDeclSyntax.self) { return value.name.text }
    if let value = declaration.as(EnumDeclSyntax.self) { return value.name.text }
    if let value = declaration.as(ActorDeclSyntax.self) { return value.name.text }
    if let value = declaration.as(ProtocolDeclSyntax.self) { return value.name.text }
    if let value = declaration.as(TypeAliasDeclSyntax.self) { return value.name.text }
    return nil
}

private func sceneRouterGeneratedMemberConflict(
    in declaration: DeclSyntax
) -> SceneRouterGeneratedMemberConflict? {
    // The generated members exist only under `#if os(visionOS)`. A client may
    // legally provide the same entry point in the complementary branch, so
    // conditional redeclarations are left to the target-aware compiler.
    if declaration.is(IfConfigDeclSyntax.self) {
        return nil
    }

    if let variable = declaration.as(VariableDeclSyntax.self),
       variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
       let reservedName = variable.bindings.lazy.compactMap({ binding in
           binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
       }).first(where: sceneRouterIsReservedMemberName) {
        return SceneRouterGeneratedMemberConflict(
            name: sceneRouterGeneratedMemberDisplayName(reservedName),
            node: Syntax(variable)
        )
    }

    if let function = declaration.as(FunctionDeclSyntax.self),
       function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
       (function.name.text == "_InnoRouterSceneContainer" ||
           (function.name.text == "scenes" &&
               function.signature.parameterClause.parameters.isEmpty)) {
        return SceneRouterGeneratedMemberConflict(
            name: sceneRouterGeneratedMemberDisplayName(function.name.text),
            node: Syntax(function)
        )
    }

    if let enumCase = declaration.as(EnumCaseDeclSyntax.self),
       enumCase.elements.contains(where: { element in
           element.name.text == "scenes" ||
               element.name.text == "_InnoRouterSceneContainer"
       }) {
        let name = enumCase.elements.contains(where: { $0.name.text == "scenes" })
            ? "static var scenes"
            : "_InnoRouterSceneContainer"
        return SceneRouterGeneratedMemberConflict(name: name, node: Syntax(enumCase))
    }

    if let reservedName = sceneRouterDeclaredTypeName(declaration),
       sceneRouterIsReservedMemberName(reservedName) {
        return SceneRouterGeneratedMemberConflict(
            name: sceneRouterGeneratedMemberDisplayName(reservedName),
            node: Syntax(declaration)
        )
    }
    return nil
}

private func sceneRouterIsReservedMemberName(_ name: String) -> Bool {
    name == "scenes" || name == "_InnoRouterSceneContainer"
}

private func sceneRouterGeneratedMemberDisplayName(_ name: String) -> String {
    name == "scenes" ? "static var scenes" : "_InnoRouterSceneContainer"
}

private func renderSceneRouterRegistryItem(_ item: SceneRouterItem) -> String {
    let route = ".\(item.caseName)"
    let id = sceneRouterStringLiteral(item.id)
    switch item.style {
    case .window:
        return ".window(\(route), id: \(id))"
    case .volumetric(let width, let height, let depth):
        return """
        .volumetric(
            \(route),
            id: \(id),
            size: InnoRouterSpatial.VolumetricSize(
                x: \(width),
                y: \(height),
                z: \(depth)
            )
        )
        """
    case .immersive(let style):
        return ".immersive(\(route), id: \(id), style: .\(style))"
    }
}

private func renderSceneRouterScene(
    _ item: SceneRouterItem,
    index: Int,
    routeType: String
) -> String {
    switch item.style {
    case .window:
        return renderSceneRouterWindow(
            item,
            routeType: routeType,
            volumetricSize: nil
        )
    case .volumetric(let width, let height, let depth):
        return renderSceneRouterWindow(
            item,
            routeType: routeType,
            volumetricSize: (width, height, depth)
        )
    case .immersive(let style):
        return renderSceneRouterImmersive(
            item,
            index: index,
            routeType: routeType,
            style: style
        )
    }
}

private func renderSceneRouterWindow(
    _ item: SceneRouterItem,
    routeType: String,
    volumetricSize: (Double, Double, Double)?
) -> String {
    var source = """
    SwiftUI.WindowGroup(
        id: \(sceneRouterStringLiteral(item.id)),
        for: Foundation.UUID.self
    ) { $sceneID in
        \(routeType).destination(for: .\(item.caseName))
            .innoRouterSceneHost(
                _innoRouterStore,
                scenes: _innoRouterScenes,
                attachedTo: .\(item.caseName),
                instanceID: sceneID
            )
    } defaultValue: {
        Foundation.UUID()
    }
    """

    if let (width, height, depth) = volumetricSize {
        source += """

        .windowStyle(SwiftUI.VolumetricWindowStyle())
        .defaultSize(
            width: \(width),
            height: \(height),
            depth: \(depth),
            in: Foundation.UnitLength.meters
        )
        """
    }
    return source
}

private func renderSceneRouterImmersive(
    _ item: SceneRouterItem,
    index: Int,
    routeType: String,
    style: String
) -> String {
    return """
    SwiftUI.ImmersiveSpace(id: \(sceneRouterStringLiteral(item.id))) {
        \(routeType).destination(for: .\(item.caseName))
            .innoRouterSceneHost(
                _innoRouterStore,
                scenes: _innoRouterScenes,
                attachedTo: .\(item.caseName)
            )
    }
    .immersionStyle(
        selection: $_innoRouterImmersionStyle\(index),
        in: \(renderSwiftUIImmersionStyle(style))
    )
    """
}

private func renderSwiftUIImmersionStyle(_ style: String) -> String {
    switch style {
    case "mixed": return "SwiftUI.MixedImmersionStyle()"
    case "progressive": return "SwiftUI.ProgressiveImmersionStyle()"
    case "full": return "SwiftUI.FullImmersionStyle()"
    default: preconditionFailure("SceneRouter style analysis must reject unknown values.")
    }
}

private func indentSceneRouterSource(_ source: String, by spaces: Int) -> String {
    let indentation = String(repeating: " ", count: spaces)
    return source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { indentation + String($0) }
        .joined(separator: "\n")
}
