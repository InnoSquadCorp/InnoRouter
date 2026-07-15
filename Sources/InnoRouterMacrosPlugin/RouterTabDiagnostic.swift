// MARK: - RouterTabDiagnostic.swift
// InnoRouterMacrosPlugin - @Router / @TabItem diagnostics
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics

enum RouterTabDiagnostic: DiagnosticMessage {
    case tabItemRequiresCase
    case tabItemRequiresRouter
    case missingTabItem(caseName: String)
    case duplicateTabItem
    case multipleCasesPerDeclaration
    case associatedValues(caseName: String)
    case invalidArguments(reason: String)
    case unavailableCase(caseName: String)
    case conditionalCase
    case conflictingMember(name: String)
    case redundantRouterTabConformance
    case redundantCaseIterableConformance

    var severity: DiagnosticSeverity {
        switch self {
        case .redundantRouterTabConformance, .redundantCaseIterableConformance:
            return .warning
        default:
            return .error
        }
    }

    var code: String {
        switch self {
        case .tabItemRequiresCase: return "InnoRouterMacro.E007"
        case .tabItemRequiresRouter: return "InnoRouterMacro.E008"
        case .missingTabItem: return "InnoRouterMacro.E009"
        case .duplicateTabItem: return "InnoRouterMacro.E010"
        case .multipleCasesPerDeclaration: return "InnoRouterMacro.E011"
        case .associatedValues: return "InnoRouterMacro.E012"
        case .invalidArguments: return "InnoRouterMacro.E013"
        case .unavailableCase: return "InnoRouterMacro.E014"
        case .conditionalCase: return "InnoRouterMacro.E015"
        case .conflictingMember: return "InnoRouterMacro.E016"
        case .redundantRouterTabConformance: return "InnoRouterMacro.W004"
        case .redundantCaseIterableConformance: return "InnoRouterMacro.W005"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .tabItemRequiresCase:
            return prefix + "@TabItem can only be attached to an enum case inside an @Router enum"
        case .tabItemRequiresRouter:
            return prefix + "@TabItem requires an enclosing @Router enum; add @Router to the enum or remove @TabItem"
        case .missingTabItem(let caseName):
            return prefix + "@Router tab case `\(caseName)` is missing @TabItem; annotate every case or remove all @TabItem annotations"
        case .duplicateTabItem:
            return prefix + "a router tab case must have exactly one @TabItem annotation; remove the duplicate"
        case .multipleCasesPerDeclaration:
            return prefix + "@TabItem requires one case per declaration; split `case first, second` into separate annotated case declarations"
        case .associatedValues(let caseName):
            return prefix + "@Router tab case `\(caseName)` cannot have associated values because RouterTab must be CaseIterable"
        case .invalidArguments(let reason):
            return prefix + "@TabItem requires @TabItem(\"Title\", systemImage: \"symbol\"): \(reason)"
        case .unavailableCase(let caseName):
            return prefix + "@Router tab case `\(caseName)` cannot be conditionally available because allCases must be stable"
        case .conditionalCase:
            return prefix + "@Router tab cases cannot be declared inside #if; declare one stable tab set for every build configuration"
        case .conflictingMember(let name):
            return prefix + "@Router with @TabItem generates `\(name)`; remove the manual declaration or remove the tab annotations"
        case .redundantRouterTabConformance:
            return prefix + "RouterTab conformance is supplied by @Router when @TabItem is present; remove the explicit conformance"
        case .redundantCaseIterableConformance:
            return prefix + "CaseIterable conformance is inherited from the RouterTab supplied by @Router; remove the explicit conformance"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: code)
    }
}
