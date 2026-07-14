// MARK: - RouterMacroDiagnostic.swift
// InnoRouterMacrosPlugin - @Router diagnostics
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics

enum RouterMacroDiagnostic: DiagnosticMessage {
    case missingDestination
    case invalidDestination(reason: String)
    case conflictingDestination
    case emptyRouter
    case redundantDestinationRouteConformance
    case redundantRouteConformance

    var severity: DiagnosticSeverity {
        switch self {
        case .missingDestination, .invalidDestination, .conflictingDestination:
            return .error
        case .emptyRouter, .redundantDestinationRouteConformance, .redundantRouteConformance:
            return .warning
        }
    }

    var code: String {
        switch self {
        case .missingDestination: return "InnoRouterMacro.E004"
        case .invalidDestination: return "InnoRouterMacro.E005"
        case .conflictingDestination: return "InnoRouterMacro.E006"
        case .emptyRouter: return "InnoRouterMacro.W001"
        case .redundantDestinationRouteConformance: return "InnoRouterMacro.W002"
        case .redundantRouteConformance: return "InnoRouterMacro.W003"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .missingDestination:
            return prefix + "@Router requires `var destination: some View { ... }` inside the enum"
        case .invalidDestination(let reason):
            return prefix + "@Router cannot use this `destination` property: \(reason). " +
                "Declare an instance computed `var destination: some View { ... }`."
        case .conflictingDestination:
            return prefix + "@Router generates `static destination(for:)`; remove the manual function or remove @Router and conform to DestinationRoute manually"
        case .emptyRouter:
            return prefix + "@Router is attached to an enum with no route cases; RouterHost can only render its root view"
        case .redundantDestinationRouteConformance:
            return prefix + "DestinationRoute conformance is supplied by @Router; remove the explicit conformance"
        case .redundantRouteConformance:
            return prefix + "Route conformance is inherited from the DestinationRoute supplied by @Router; remove the explicit conformance"
        }
    }

    var diagnosticID: MessageID {
        switch self {
        case .missingDestination:
            return MessageID(domain: "InnoRouterMacros", id: "routerMissingDestination")
        case .invalidDestination:
            return MessageID(domain: "InnoRouterMacros", id: "routerInvalidDestination")
        case .conflictingDestination:
            return MessageID(domain: "InnoRouterMacros", id: "routerConflictingDestination")
        case .emptyRouter:
            return MessageID(domain: "InnoRouterMacros", id: "routerEmptyEnum")
        case .redundantDestinationRouteConformance:
            return MessageID(domain: "InnoRouterMacros", id: "routerRedundantConformance")
        case .redundantRouteConformance:
            return MessageID(domain: "InnoRouterMacros", id: "routerRedundantRouteConformance")
        }
    }
}
