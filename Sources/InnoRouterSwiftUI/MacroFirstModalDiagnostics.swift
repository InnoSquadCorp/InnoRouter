import OSLog

import InnoRouterCore

private let macroFirstModalLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "macro-first-modal"
)

extension ModalStoreConfiguration {
    /// Adds cancellation diagnostics for a locally owned macro-first modal
    /// host while preserving the caller's observation hook.
    @MainActor
    func withMacroFirstDiagnostics(hostName: String) -> Self {
        var result = self
        let userOnEvent = onEvent

        result.onEvent = { event in
            userOnEvent?(event)

            guard case .commandIntercepted(let command, .cancelled(let reason)) = event else {
                return
            }

            macroFirstModalLogger.warning(
                """
                \(hostName, privacy: .public) rejected a modal command. \
                route=\(String(reflecting: M.self), privacy: .private(mask: .hash)) \
                command=\(String(describing: command), privacy: .private(mask: .hash)) \
                reason=\(reason.localizedDescription, privacy: .private(mask: .hash))
                """
            )
        }

        return result
    }
}
