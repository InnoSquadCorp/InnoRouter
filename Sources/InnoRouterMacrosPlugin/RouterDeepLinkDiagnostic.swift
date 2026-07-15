// MARK: - RouterDeepLinkDiagnostic.swift
// InnoRouterMacrosPlugin - @Router / @DeepLink diagnostics
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

enum RouterDeepLinkDiagnostic: DiagnosticMessage {
    case requiresCase
    case requiresRouter
    case invalidRouterArguments(reason: String)
    case missingAllowlist
    case duplicateMarker
    case multipleCasesPerDeclaration
    case invalidPattern(reason: String)
    case unavailableCase(caseName: String)
    case conditionalCase
    case invalidAssociatedValue(reason: String)
    case patternPayloadMismatch(reason: String)
    case unreachablePattern(reason: String)
    case typedFallbackPattern(reason: String)
    case conflictingResolver
    case unusedAllowlist
    case redundantConformance

    var severity: DiagnosticSeverity {
        switch self {
        case .typedFallbackPattern, .unusedAllowlist, .redundantConformance:
            return .warning
        default:
            return .error
        }
    }

    var code: String {
        switch self {
        case .requiresCase: return "InnoRouterMacro.E017"
        case .requiresRouter: return "InnoRouterMacro.E018"
        case .invalidRouterArguments: return "InnoRouterMacro.E019"
        case .missingAllowlist: return "InnoRouterMacro.E020"
        case .duplicateMarker: return "InnoRouterMacro.E021"
        case .multipleCasesPerDeclaration: return "InnoRouterMacro.E022"
        case .invalidPattern: return "InnoRouterMacro.E023"
        case .unavailableCase: return "InnoRouterMacro.E024"
        case .conditionalCase: return "InnoRouterMacro.E025"
        case .invalidAssociatedValue: return "InnoRouterMacro.E026"
        case .patternPayloadMismatch: return "InnoRouterMacro.E027"
        case .unreachablePattern: return "InnoRouterMacro.E028"
        case .conflictingResolver: return "InnoRouterMacro.E029"
        case .unusedAllowlist: return "InnoRouterMacro.W006"
        case .redundantConformance: return "InnoRouterMacro.W007"
        case .typedFallbackPattern: return "InnoRouterMacro.W012"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .requiresCase:
            return prefix + "@DeepLink can only be attached to an enum case inside an @Router enum"
        case .requiresRouter:
            return prefix + "@DeepLink requires the nearest enclosing enum to use @Router"
        case .invalidRouterArguments(let reason):
            return prefix + "@Router deep-link allowlists are invalid: \(reason)"
        case .missingAllowlist:
            return prefix + "@DeepLink requires nonempty literal deepLinkSchemes and deepLinkHosts allowlists on @Router"
        case .duplicateMarker:
            return prefix + "a route case must have exactly one @DeepLink annotation; remove the duplicate"
        case .multipleCasesPerDeclaration:
            return prefix + "@DeepLink requires one case per declaration; split joined enum cases into separate declarations"
        case .invalidPattern(let reason):
            return prefix + "@DeepLink pattern is invalid: \(reason)"
        case .unavailableCase(let caseName):
            return prefix + "deep-link case `\(caseName)` cannot be conditionally available"
        case .conditionalCase:
            return prefix + "@DeepLink cases cannot be declared inside #if; keep the mapping set stable"
        case .invalidAssociatedValue(let reason):
            return prefix + "@DeepLink associated value is unsupported: \(reason)"
        case .patternPayloadMismatch(let reason):
            return prefix + "@DeepLink pattern and case payload do not match: \(reason)"
        case .unreachablePattern(let reason):
            return prefix + "@DeepLink mapping is unreachable: \(reason)"
        case .typedFallbackPattern(let reason):
            return prefix + "@DeepLink mappings overlap: \(reason)"
        case .conflictingResolver:
            return prefix + "@Router with @DeepLink generates `resolveDeepLink(_:)`; remove the manual static resolver"
        case .unusedAllowlist:
            return prefix + "deep-link allowlists have no effect because this @Router has no @DeepLink cases"
        case .redundantConformance:
            return prefix + "DeepLinkRoute conformance is supplied by @Router when @DeepLink is present; remove the explicit conformance"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: code)
    }
}

struct DeepLinkFirstMappingNote: NoteMessage {
    var message: String {
        "The earlier mapping that takes precedence is declared here."
    }

    var noteID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "deepLinkFirstMapping")
    }
}

struct DeepLinkPrecedingMappingNote: NoteMessage {
    var message: String {
        "A preceding overlapping mapping is declared here."
    }

    var noteID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: "deepLinkPrecedingMapping")
    }
}

func diagnoseDeepLink(
    _ message: RouterDeepLinkDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(Diagnostic(node: node, message: message))
}

func diagnoseUnreachableDeepLink(
    reason: String,
    at node: some SyntaxProtocol,
    firstMapping: some SyntaxProtocol,
    context: some MacroExpansionContext
) {
    context.diagnose(
        Diagnostic(
            node: node,
            message: RouterDeepLinkDiagnostic.unreachablePattern(reason: reason),
            notes: [
                Note(node: Syntax(firstMapping), message: DeepLinkFirstMappingNote())
            ]
        )
    )
}

func diagnoseTypedFallbackDeepLink(
    reason: String,
    at node: some SyntaxProtocol,
    precedingMappings: [AttributeSyntax],
    context: some MacroExpansionContext
) {
    context.diagnose(
        Diagnostic(
            node: node,
            message: RouterDeepLinkDiagnostic.typedFallbackPattern(reason: reason),
            notes: precedingMappings.map {
                Note(node: Syntax($0), message: DeepLinkPrecedingMappingNote())
            }
        )
    )
}
