import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Empty peer marker consumed and validated by `RouterMacro`.
public struct FeatureRouteMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(EnumCaseDeclSyntax.self) else {
            diagnoseFeature(.requiresCase, at: node, context: context)
            return []
        }
        guard let nearestEnum = context.lexicalContext.lazy.compactMap({
            $0.as(EnumDeclSyntax.self)
        }).first,
            nearestEnum.attributes.contains(where: { element in
                guard let attribute = element.as(AttributeSyntax.self) else { return false }
                return attributeBaseName(attribute) == "Router"
            }) else {
            diagnoseFeature(.requiresRouter, at: node, context: context)
            return []
        }
        return []
    }
}

func diagnoseFeature(
    _ message: RouterFeatureDiagnostic,
    at node: some SyntaxProtocol,
    context: some MacroExpansionContext,
    fixIts: [FixIt] = []
) {
    context.diagnose(Diagnostic(node: node, message: message, fixIts: fixIts))
}
