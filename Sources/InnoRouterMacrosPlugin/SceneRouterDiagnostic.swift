// MARK: - SceneRouterDiagnostic.swift
// InnoRouterMacrosPlugin - @Router / @Scene diagnostics
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics

enum SceneRouterDiagnostic: DiagnosticMessage {
    case sceneRequiresCase
    case sceneRequiresRouter
    case conditionalCase
    case duplicateScene
    case multipleCasesPerDeclaration
    case associatedValues(caseName: String)
    case unavailableCase(caseName: String)
    case invalidArguments(reason: String)
    case duplicateID(String)
    case generatedMemberConflict(name: String)

    var severity: DiagnosticSeverity { .error }

    var code: String {
        switch self {
        case .sceneRequiresCase: return "InnoRouterMacro.E030"
        case .sceneRequiresRouter: return "InnoRouterMacro.E031"
        case .conditionalCase: return "InnoRouterMacro.E035"
        case .duplicateScene: return "InnoRouterMacro.E038"
        case .multipleCasesPerDeclaration: return "InnoRouterMacro.E039"
        case .associatedValues: return "InnoRouterMacro.E040"
        case .unavailableCase: return "InnoRouterMacro.E041"
        case .invalidArguments: return "InnoRouterMacro.E042"
        case .duplicateID: return "InnoRouterMacro.E044"
        case .generatedMemberConflict: return "InnoRouterMacro.E048"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .sceneRequiresCase:
            return prefix + "@Scene can only be attached to an enum case inside an @Router enum"
        case .sceneRequiresRouter:
            return prefix + "@Scene requires the nearest enclosing enum to use @Router"
        case .conditionalCase:
            return prefix + "@Scene cases and attributes cannot be declared inside #if; keep the scene catalog stable across builds"
        case .duplicateScene:
            return prefix + "a route case must have exactly one @Scene annotation"
        case .multipleCasesPerDeclaration:
            return prefix + "@Scene requires one case per declaration"
        case .associatedValues(let caseName):
            return prefix + "scene route `\(caseName)` cannot have associated values; move instance state into the destination model"
        case .unavailableCase(let caseName):
            return prefix + "scene route `\(caseName)` cannot be conditionally available"
        case .invalidArguments(let reason):
            return prefix + "@Scene arguments are invalid: \(reason)"
        case .duplicateID(let id):
            return prefix + "@Scene id `\(id)` is duplicated; every scene identifier must be unique"
        case .generatedMemberConflict(let name):
            return prefix + "@Router with @Scene generates `\(name)`; remove the manual declaration or all scene markers"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: code)
    }
}
