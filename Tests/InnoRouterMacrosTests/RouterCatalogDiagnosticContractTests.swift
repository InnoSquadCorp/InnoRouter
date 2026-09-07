#if canImport(InnoRouterMacrosPlugin)
import SwiftDiagnostics
import Testing

@testable import InnoRouterMacrosPlugin

@Suite("Router catalog diagnostic contracts")
struct RouterCatalogDiagnosticContractTests {
    @Test("Every @Scene diagnostic has a stable unique error code and actionable message")
    func sceneDiagnostics() {
        let diagnostics: [(SceneRouterDiagnostic, String, String)] = [
            (.sceneRequiresCase, "InnoRouterMacro.E030", "enum case"),
            (.sceneRequiresRouter, "InnoRouterMacro.E031", "@Router"),
            (.conditionalCase, "InnoRouterMacro.E035", "#if"),
            (.duplicateScene, "InnoRouterMacro.E038", "exactly one"),
            (.multipleCasesPerDeclaration, "InnoRouterMacro.E039", "one case"),
            (.associatedValues(caseName: "detail"), "InnoRouterMacro.E040", "detail"),
            (.unavailableCase(caseName: "settings"), "InnoRouterMacro.E041", "settings"),
            (.invalidArguments(reason: "missing id"), "InnoRouterMacro.E042", "missing id"),
            (.duplicateID("main"), "InnoRouterMacro.E044", "main"),
            (.generatedMemberConflict(name: "sceneCatalog"), "InnoRouterMacro.E048", "sceneCatalog"),
        ]

        #expect(Set(diagnostics.map { $0.0.code }).count == diagnostics.count)
        for (diagnostic, code, detail) in diagnostics {
            #expect(diagnostic.code == code)
            #expect(diagnostic.severity == .error)
            #expect(diagnostic.message.hasPrefix("[\(code)] "))
            #expect(diagnostic.message.contains(detail))
            #expect(diagnostic.diagnosticID == MessageID(domain: "InnoRouterMacros", id: code))
        }
    }

    @Test("Every @TabItem diagnostic has a stable unique code, severity, and actionable message")
    func tabDiagnostics() {
        let diagnostics: [(RouterTabDiagnostic, String, DiagnosticSeverity, String)] = [
            (.tabItemRequiresCase, "InnoRouterMacro.E007", .error, "enum case"),
            (.tabItemRequiresRouter, "InnoRouterMacro.E008", .error, "@Router"),
            (.duplicateTabItem, "InnoRouterMacro.E010", .error, "exactly one"),
            (.multipleCasesPerDeclaration, "InnoRouterMacro.E011", .error, "one case"),
            (.associatedValues(caseName: "profile"), "InnoRouterMacro.E012", .error, "profile"),
            (.invalidArguments(reason: "missing title"), "InnoRouterMacro.E013", .error, "missing title"),
            (.unavailableCase(caseName: "admin"), "InnoRouterMacro.E014", .error, "admin"),
            (.conditionalCase, "InnoRouterMacro.E015", .error, "#if"),
            (.conflictingMember(name: "tabCatalog"), "InnoRouterMacro.E016", .error, "tabCatalog"),
            (.redundantRouterTabConformance, "InnoRouterMacro.W004", .warning, "conformance"),
        ]

        #expect(Set(diagnostics.map { $0.0.code }).count == diagnostics.count)
        for (diagnostic, code, severity, detail) in diagnostics {
            #expect(diagnostic.code == code)
            #expect(diagnostic.severity == severity)
            #expect(diagnostic.message.hasPrefix("[\(code)] "))
            #expect(diagnostic.message.contains(detail))
            #expect(diagnostic.diagnosticID == MessageID(domain: "InnoRouterMacros", id: code))
        }
    }
}
#endif
