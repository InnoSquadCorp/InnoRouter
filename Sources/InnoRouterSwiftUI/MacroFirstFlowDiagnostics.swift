import OSLog

import InnoRouterCore

private let macroFirstFlowLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "macro-first-flow"
)

extension FlowStoreConfiguration {
    /// Adds the diagnostics promised by the locally owned macro-first host
    /// while preserving the caller's observation hook.
    ///
    /// External `FlowStore` construction intentionally does not use this
    /// helper, so advanced `FlowHost` integrations retain their configured
    /// logging policy exactly.
    @MainActor
    func withMacroFirstDiagnostics(hostName: String) -> Self {
        var result = self
        let existingDiagnosticHandler = rejectionDiagnosticHandler

        result.rejectionDiagnosticHandler = { intent, context in
            existingDiagnosticHandler?(intent, context)

            macroFirstFlowLogger.warning(
                """
                \(hostName, privacy: .public) rejected a flow intent. \
                route=\(String(reflecting: R.self), privacy: .private(mask: .hash)) \
                intent=\(String(describing: intent), privacy: .private(mask: .hash)) \
                origin=\(context.origin.rawValue, privacy: .public) \
                detail=\(context.detail, privacy: .private(mask: .hash))
                """
            )
        }

        return result
    }
}
