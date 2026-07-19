// MARK: - FlowRejectionDiagnosticContext.swift
// InnoRouterSwiftUI — internal detail retained behind the 5.x rejection API.

import InnoRouterCore

/// Internal rejection provenance used by generated macro-first hosts.
///
/// `FlowRejectionReason` intentionally stays source-compatible in 5.x, so
/// anonymous middleware cancellation and navigation-engine failure can both
/// surface publicly as `.middlewareRejected(debugName: nil)`. This context
/// preserves the distinction for diagnostics without adding another public
/// rejection case.
struct FlowRejectionDiagnosticContext: Sendable, Equatable {
    enum Origin: String, Sendable, Equatable {
        case flowInvariant = "flow-invariant"
        case navigationCancellation = "navigation-cancellation"
        case navigationEngine = "navigation-engine"
        case modalCancellation = "modal-cancellation"
        case reentrantApply = "reentrant-apply"
    }

    let origin: Origin
    let detail: String
}

typealias FlowRejectionDiagnosticHandler<R: Route> =
    @MainActor @Sendable (FlowIntent<R>, FlowRejectionDiagnosticContext) -> Void
