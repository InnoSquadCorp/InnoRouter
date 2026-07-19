import InnoRouterCore

@MainActor
enum NavigationRestorationApplyResult<R: Route> {
    case restored
    case rejected(NavigationResult<R>)
    case stateMismatch(actualPath: [R])
}

@MainActor
extension NavigationStore {
    /// Validates and previews a persisted path, committing only when the
    /// middleware-adjusted result exactly matches the decoded snapshot.
    func restorePathAtomically(_ path: [R]) throws -> NavigationRestorationApplyResult<R> {
        try validateRestoredPath(path)

        let journal = previewFlowCommand(.replace(path), from: state)
        guard journal.result.isSuccess else {
            if journal.stateAfter == journal.stateBefore {
                _ = commitFlowPreview(journal)
            } else {
                discardFlowPreview(journal)
            }
            return .rejected(journal.result)
        }

        guard journal.stateAfter.path == path else {
            discardFlowPreview(journal)
            return .stateMismatch(actualPath: journal.stateAfter.path)
        }

        _ = commitFlowPreview(journal)
        return .restored
    }
}
