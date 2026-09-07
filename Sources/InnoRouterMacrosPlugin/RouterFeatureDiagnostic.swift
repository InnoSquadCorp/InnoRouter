import SwiftDiagnostics

enum RouterFeatureDiagnostic: DiagnosticMessage {
    case requiresCase
    case requiresRouter
    case duplicateAttribute
    case multipleCases
    case invalidPayload(caseName: String)
    case invalidID
    case duplicateID(String)
    case conditionalCase
    case unavailableCase(String)
    case conflictingMember(String)

    var severity: DiagnosticSeverity { .error }

    var code: String {
        switch self {
        case .requiresCase: return "InnoRouterMacro.E058"
        case .requiresRouter: return "InnoRouterMacro.E059"
        case .duplicateAttribute: return "InnoRouterMacro.E060"
        case .multipleCases: return "InnoRouterMacro.E061"
        case .invalidPayload: return "InnoRouterMacro.E062"
        case .invalidID: return "InnoRouterMacro.E063"
        case .duplicateID: return "InnoRouterMacro.E064"
        case .conditionalCase: return "InnoRouterMacro.E065"
        case .unavailableCase: return "InnoRouterMacro.E066"
        case .conflictingMember: return "InnoRouterMacro.E067"
        }
    }

    var message: String {
        let prefix = "[\(code)] "
        switch self {
        case .requiresCase:
            return prefix + "@FeatureRoute can only be attached to an enum case inside an @Router enum"
        case .requiresRouter:
            return prefix + "@FeatureRoute requires the nearest enclosing enum to use @Router"
        case .duplicateAttribute:
            return prefix + "a feature case must have exactly one @FeatureRoute annotation"
        case .multipleCases:
            return prefix + "@FeatureRoute requires one case per declaration"
        case .invalidPayload(let name):
            return prefix + "feature case `\(name)` must carry exactly one associated route value"
        case .invalidID:
            return prefix + "@FeatureRoute requires either no argument or one nonempty string literal instance ID"
        case .duplicateID(let id):
            return prefix + "feature instance ID `\(id)` is already used by another @FeatureRoute case"
        case .conditionalCase:
            return prefix + "@FeatureRoute cases cannot be conditional because the generated composition catalog must be stable"
        case .unavailableCase(let name):
            return prefix + "feature case `\(name)` cannot be conditionally available"
        case .conflictingMember(let name):
            return prefix + "@Router with @FeatureRoute generates `\(name)`; remove the manual declaration or feature annotations"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "InnoRouterMacros", id: code)
    }
}
