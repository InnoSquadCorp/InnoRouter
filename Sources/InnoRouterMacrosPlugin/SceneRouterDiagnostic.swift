// MARK: - SceneRouterDiagnostic.swift
// InnoRouterMacrosPlugin - @SceneRouter / @Scene diagnostics
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics

enum SceneRouterDiagnostic: DiagnosticMessage {
    case sceneRequiresCase
    case sceneRequiresSceneRouter
    case conflictsWithRouter
    case emptyRouter
    case unsupportedGenericRouter
    case conditionalCase
    case conditionalAttributes(caseName: String)
    case missingScene(caseName: String)
    case duplicateScene
    case multipleCasesPerDeclaration
    case associatedValues(caseName: String)
    case unavailableCase(caseName: String)
    case invalidArguments(reason: String)
    case invalidSize(reason: String)
    case duplicateID(String)
    case missingDestination
    case invalidDestination(reason: String)
    case conflictingDestination
    case generatedMemberConflict(name: String)
    case invalidRouterArguments(reason: String)
    case redundantDestinationRouteConformance
    case redundantRouteConformance
    case immersivePrimaryHost
    case unusedImmersiveLaunch

    var severity: DiagnosticSeverity {
        switch self {
        case .redundantDestinationRouteConformance,
             .redundantRouteConformance,
             .immersivePrimaryHost,
             .unusedImmersiveLaunch:
            return .warning
        default:
            return .error
        }
    }

    var code: String {
        switch self {
        case .sceneRequiresCase: return "InnoRouterMacro.E030"
        case .sceneRequiresSceneRouter: return "InnoRouterMacro.E031"
        case .conflictsWithRouter: return "InnoRouterMacro.E032"
        case .emptyRouter: return "InnoRouterMacro.E033"
        case .unsupportedGenericRouter: return "InnoRouterMacro.E034"
        case .conditionalCase: return "InnoRouterMacro.E035"
        case .conditionalAttributes: return "InnoRouterMacro.E036"
        case .missingScene: return "InnoRouterMacro.E037"
        case .duplicateScene: return "InnoRouterMacro.E038"
        case .multipleCasesPerDeclaration: return "InnoRouterMacro.E039"
        case .associatedValues: return "InnoRouterMacro.E040"
        case .unavailableCase: return "InnoRouterMacro.E041"
        case .invalidArguments: return "InnoRouterMacro.E042"
        case .invalidSize: return "InnoRouterMacro.E043"
        case .duplicateID: return "InnoRouterMacro.E044"
        case .missingDestination: return "InnoRouterMacro.E045"
        case .invalidDestination: return "InnoRouterMacro.E046"
        case .conflictingDestination: return "InnoRouterMacro.E047"
        case .generatedMemberConflict: return "InnoRouterMacro.E048"
        case .invalidRouterArguments: return "InnoRouterMacro.E049"
        case .redundantDestinationRouteConformance: return "InnoRouterMacro.W008"
        case .redundantRouteConformance: return "InnoRouterMacro.W009"
        case .immersivePrimaryHost: return "InnoRouterMacro.W010"
        case .unusedImmersiveLaunch: return "InnoRouterMacro.W011"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .sceneRequiresCase:
            return prefix + "@Scene can only be attached to an enum case inside an @SceneRouter enum"
        case .sceneRequiresSceneRouter:
            return prefix + "@Scene requires the nearest enclosing enum to use @SceneRouter"
        case .conflictsWithRouter:
            return prefix + "@SceneRouter already supplies route destinations; remove @Router and keep only @SceneRouter"
        case .emptyRouter:
            return prefix + "@SceneRouter requires at least one scene case"
        case .unsupportedGenericRouter:
            return prefix + "@SceneRouter does not support generic enums because scene cases must form one concrete app inventory"
        case .conditionalCase:
            return prefix + "@SceneRouter cases cannot be declared inside #if; keep the scene inventory stable across builds"
        case .conditionalAttributes(let caseName):
            return prefix + "scene case `\(caseName)` cannot use conditionally compiled attributes"
        case .missingScene(let caseName):
            return prefix + "scene case `\(caseName)` requires exactly one @Scene annotation"
        case .duplicateScene:
            return prefix + "a scene case must have exactly one @Scene annotation; remove the duplicate"
        case .multipleCasesPerDeclaration:
            return prefix + "@Scene requires one case per declaration; split joined enum cases into separate declarations"
        case .associatedValues(let caseName):
            return prefix + "scene case `\(caseName)` cannot have associated values; move destination state into the scene's view model"
        case .unavailableCase(let caseName):
            return prefix + "scene case `\(caseName)` cannot be conditionally available"
        case .invalidArguments(let reason):
            return prefix + "@Scene arguments are invalid: \(reason)"
        case .invalidSize(let reason):
            return prefix + "@Scene volumetric size is invalid: \(reason)"
        case .duplicateID(let id):
            return prefix + "@Scene id `\(id)` is duplicated; every scene identifier must be unique"
        case .missingDestination:
            return prefix + "@SceneRouter requires `var destination: some View { ... }` inside the enum"
        case .invalidDestination(let reason):
            return prefix + "@SceneRouter cannot use this `destination` property: \(reason). " +
                "Declare an instance computed `var destination: some View { ... }`."
        case .conflictingDestination:
            return prefix + "@SceneRouter generates `static destination(for:)`; remove the manual function or remove @SceneRouter and conform to DestinationRoute manually"
        case .generatedMemberConflict(let name):
            return prefix + "@SceneRouter generates `\(name)`; remove the manual declaration or remove @SceneRouter and compose spatial scenes manually"
        case .invalidRouterArguments(let reason):
            return prefix + "@SceneRouter arguments are invalid: \(reason)"
        case .redundantDestinationRouteConformance:
            return prefix + "DestinationRoute conformance is supplied by @SceneRouter; remove the explicit conformance"
        case .redundantRouteConformance:
            return prefix + "Route conformance is inherited from the DestinationRoute supplied by @SceneRouter; remove the explicit conformance"
        case .immersivePrimaryHost:
            return prefix + "the first @SceneRouter case becomes the primary host, but an immersive host cannot dispatch until the system opens it; move a window or volume first, or set `UIApplicationPreferredDefaultSceneSessionRole` to `UISceneSessionRoleImmersiveSpaceApplication` and acknowledge it with `@SceneRouter(immersiveLaunch: true)`"
        case .unusedImmersiveLaunch:
            return prefix + "`immersiveLaunch: true` is only needed when the first scene is immersive; remove it while a window or volume is the primary host"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: code)
    }
}
