import OSLog

import InnoRouterCore

private let flowStoreInitialPathLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "flow-store-initial-path"
)

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
        validatedInitial(steps) { error in
            flowStoreInitialPathLogger.warning(
                """
                FlowStore coerced an invalid initial path to empty. \
                route=\(String(reflecting: R.self), privacy: .private(mask: .hash)) \
                violation=\(String(describing: error), privacy: .public). \
                Use FlowStore(validating:configuration:) for external input.
                """
            )
        }
    }

    static func validatedInitial(
        _ steps: [RouteStep<R>],
        onInvalid: (FlowPlanValidationError) -> Void
    ) -> [RouteStep<R>] {
        do {
            try FlowPlan<R>.validate(steps)
            return steps
        } catch let error as FlowPlanValidationError {
            onInvalid(error)
            return []
        } catch {
            assertionFailure("Unexpected FlowPlan validation error: \(error)")
            return []
        }
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
