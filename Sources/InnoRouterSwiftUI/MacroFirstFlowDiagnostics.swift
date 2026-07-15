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
    func withMacroFirstDiagnostics() -> Self {
        var result = self
        let userOnEvent = onEvent

        result.onEvent = { event in
            userOnEvent?(event)

            guard case .intentRejected(let intent, let reason) = event else {
                return
            }

            macroFirstFlowLogger.warning(
                """
                RouterHost rejected a flow intent. \
                route=\(String(reflecting: R.self), privacy: .private(mask: .hash)) \
                intent=\(String(describing: intent), privacy: .private(mask: .hash)) \
                reason=\(reason.localizedDescription, privacy: .private(mask: .hash))
                """
            )
        }

        return result
    }
}
