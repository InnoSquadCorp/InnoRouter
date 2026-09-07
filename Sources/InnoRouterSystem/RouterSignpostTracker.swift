import InnoRouterCore

enum RouterSignpostPoint {
    case lifecycle
    case outcome
}

/// Owns interval lifetimes independently of the Instruments transport so every
/// termination path can be tested without depending on system log collection.
@MainActor
final class RouterSignpostTracker<Interval> {
    private var activeIntervals: [RouterTransitionID: Interval] = [:]
    private let begin: @MainActor () -> Interval
    private let end: @MainActor (Interval) -> Void
    private let point: @MainActor (RouterSignpostPoint, Interval?) -> Void

    init(
        begin: @escaping @MainActor () -> Interval,
        end: @escaping @MainActor (Interval) -> Void,
        point: @escaping @MainActor (RouterSignpostPoint, Interval?) -> Void
    ) {
        self.begin = begin
        self.end = end
        self.point = point
    }

    isolated deinit {
        for interval in activeIntervals.values {
            end(interval)
        }
    }

    func record(_ event: RouterDiagnosticEvent) {
        switch event.kind {
        case .started:
            if let previous = activeIntervals.removeValue(forKey: event.transitionID) {
                end(previous)
            }
            activeIntervals[event.transitionID] = begin()
        case .committed, .unchanged, .deferred,
             .rejectedMutation, .rejectedPolicy, .rejectedBusy,
             .rejectedCoalesced, .rejectedSuperseded,
             .rejectedQueueOverflow, .rejectedPolicyTimeout,
             .rejectedDeferral, .rejectedStaleState,
             .rejectedCancelled, .rejectedMissingAuthority:
            if let active = activeIntervals.removeValue(forKey: event.transitionID) {
                end(active)
            } else {
                point(.outcome, nil)
            }
        case .policyAllowed, .policyDeferred, .policyRejected, .platformAdapted:
            point(.lifecycle, activeIntervals[event.transitionID])
        }
    }
}
