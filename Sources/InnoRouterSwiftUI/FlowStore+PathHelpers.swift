import InnoRouterCore

// MARK: - Path validation, decomposition, and trace helpers
//
// Internal static helpers extracted from `FlowStore.swift` so the
// primary class definition stays focused on the `Observable`
// projection + intent dispatch surface. Visibility is bumped from
// `private` to `internal` because the call sites in the main file
// cross file boundaries; the helpers remain absent from the
// public-API baseline because none of them are `public`.
extension FlowStore {

    static func validatedInitial(_ steps: [RouteStep<R>]) -> [RouteStep<R>] {
        isValidPath(steps) ? steps : []
    }

    static func isValidPath(_ steps: [RouteStep<R>]) -> Bool {
        let modalIndices = steps.enumerated().filter { $0.element.isModal }.map(\.offset)
        if modalIndices.isEmpty { return true }
        if modalIndices.count > 1 { return false }
        return modalIndices.first == steps.count - 1
    }

    static func decompose(
        _ steps: [RouteStep<R>]
    ) -> (pushRoutes: [R], modalTail: RouteStep<R>?) {
        guard let last = steps.last, last.isModal else {
            return (steps.map(\.route), nil)
        }
        return (steps.dropLast().map(\.route), last)
    }

    static func presentation(for step: RouteStep<R>) -> ModalPresentation<R> {
        guard let style = step.modalStyle else {
            preconditionFailure("Cannot build ModalPresentation from non-modal step \(step)")
        }
        return ModalPresentation(route: step.route, style: style)
    }

    static func matchesPresentationSemantics(
        _ lhs: ModalPresentation<R>?,
        _ rhs: ModalPresentation<R>?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.route == rhs.route && lhs.style == rhs.style
        default:
            return false
        }
    }

    nonisolated static func step(for presentation: ModalPresentation<R>) -> RouteStep<R> {
        switch presentation.style {
        case .sheet:
            return .sheet(presentation.route)
        case .fullScreenCover:
            return .cover(presentation.route)
        }
    }

    static func debugName(from reason: NavigationCancellationReason<R>) -> String? {
        switch reason {
        case .middleware(let debugName, _): return debugName
        case .conditionFailed: return nil
        case .custom: return nil
        case .staleAfterPrepare: return nil
        }
    }

    static func debugName(from reason: ModalCancellationReason<R>) -> String? {
        switch reason {
        case .middleware(let debugName, _): return debugName
        case .conditionFailed: return nil
        case .custom: return nil
        }
    }

    static func debugName(from result: NavigationResult<R>) -> String? {
        guard case .cancelled(let reason) = result else { return nil }
        return debugName(from: reason)
    }

    static func traceOutcome(
        for result: FlowPlanApplyResult<R>
    ) -> String {
        switch result {
        case .applied:
            return "applied"
        case .rejected:
            return "rejected"
        }
    }
}
