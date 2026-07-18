import OSLog

import InnoRouterCore

extension Logger {
    /// Shared debug formatting for internal execution-trace records.
    ///
    /// `NavigationStore` and `ModalStore` emit identical span records and
    /// differ only in the store label, so the log shape lives here once.
    /// Span identifiers and the operation name are public; metadata and
    /// outcomes can carry route payloads and stay private.
    func logExecutionTrace(_ record: InternalExecutionTraceRecord, label: String) {
        switch record {
        case .start(let context, let operation, let metadata):
            let metadataSummary = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            debug(
                """
                \(label, privacy: .public) trace start \
                root=\(context.rootID, privacy: .public) \
                span=\(context.spanID, privacy: .public) \
                parent=\(context.parentSpanID ?? "nil", privacy: .public) \
                operation=\(operation, privacy: .public) \
                metadata=\(metadataSummary, privacy: .private)
                """
            )

        case .finish(let context, let operation, let outcome):
            debug(
                """
                \(label, privacy: .public) trace finish \
                root=\(context.rootID, privacy: .public) \
                span=\(context.spanID, privacy: .public) \
                parent=\(context.parentSpanID ?? "nil", privacy: .public) \
                operation=\(operation, privacy: .public) \
                outcome=\(outcome, privacy: .private)
                """
            )
        }
    }
}
