import Testing

import InnoRouter
@testable import InnoRouterSystem

@Suite("Signpost interval ownership")
@MainActor
struct RouterSignpostTrackerTests {
    @Test("Every terminal outcome closes its interval exactly once", arguments: [
        RouterDiagnosticEventKind.committed, .unchanged, .deferred,
        .rejectedMutation, .rejectedPolicy, .rejectedBusy, .rejectedCoalesced,
        .rejectedSuperseded, .rejectedQueueOverflow, .rejectedPolicyTimeout,
        .rejectedDeferral, .rejectedStaleState, .rejectedCancelled, .rejectedMissingAuthority,
    ])
    func terminalOutcomes(kind: RouterDiagnosticEventKind) {
        let sink = SignpostTestSink()
        var tracker: RouterSignpostTracker<Int>? = sink.tracker()
        let id = RouterTransitionID()
        tracker?.record(.init(kind: .started, transitionID: id))
        tracker?.record(.init(kind: kind, transitionID: id))
        tracker?.record(.init(kind: kind, transitionID: id))
        tracker = nil
        #expect(sink.calls == ["begin:1", "end:1", "outcome:nil"])
    }

    @Test("Interleaved transitions retain correlation and teardown closes only outstanding work")
    func correlationAndTeardown() {
        let sink = SignpostTestSink()
        var tracker: RouterSignpostTracker<Int>? = sink.tracker()
        let first = RouterTransitionID()
        let second = RouterTransitionID()
        tracker?.record(.init(kind: .started, transitionID: first))
        tracker?.record(.init(kind: .started, transitionID: second))
        tracker?.record(.init(kind: .policyAllowed, transitionID: first))
        tracker?.record(.init(kind: .policyDeferred, transitionID: second))
        tracker?.record(.init(kind: .policyRejected, transitionID: first))
        tracker?.record(.init(kind: .platformAdapted, transitionID: second))
        tracker?.record(.init(kind: .committed, transitionID: first))
        tracker?.record(.init(kind: .platformAdapted, transitionID: first))
        tracker = nil
        #expect(sink.calls == [
            "begin:1", "begin:2", "lifecycle:1", "lifecycle:2",
            "lifecycle:1", "lifecycle:2", "end:1", "lifecycle:nil", "end:2",
        ])
    }

    @Test("Repeated starts close the previous interval before replacing it")
    func duplicateStarts() {
        let sink = SignpostTestSink()
        var tracker: RouterSignpostTracker<Int>? = sink.tracker()
        let id = RouterTransitionID()
        tracker?.record(.init(kind: .started, transitionID: id))
        tracker?.record(.init(kind: .started, transitionID: id))
        tracker = nil
        #expect(sink.calls == ["begin:1", "end:1", "begin:2", "end:2"])
    }
}

@MainActor
private final class SignpostTestSink {
    var calls: [String] = []
    private var nextID = 0

    func tracker() -> RouterSignpostTracker<Int> {
        RouterSignpostTracker(
            begin: {
                self.nextID += 1
                self.calls.append("begin:\(self.nextID)")
                return self.nextID
            },
            end: { self.calls.append("end:\($0)") },
            point: { kind, id in
                let label = kind == .outcome ? "outcome" : "lifecycle"
                self.calls.append("\(label):\(id.map(String.init) ?? "nil")")
            }
        )
    }
}
