import Foundation

import InnoRouterCore
import InnoRouterSwiftUI

public enum RouterScenarioTerminal: String, Hashable, Sendable, Codable {
    case applied
    case unchanged
    case deferred
    case rejected
}

/// Stable rejection categories that can be compared across independent runs
/// without serializing transition IDs or application messages.
public enum RouterScenarioRejectionKind: String, Hashable, Sendable, Codable {
    case mutation, featureProjection, policy, busy, coalesced, superseded
    case queueOverflow, policyTimedOut, deferralConflict, deferralNotFound
    case deferralCapacityExceeded, deferralExpired, deferralEvicted, staleState
    case cancelled, missingAuthority
}

/// Developer-authored expectations kept separate from captured observations.
public struct RouterScenarioExpectation<R: Route & Codable>: Hashable, Sendable, Codable {
    public let state: RouterState<R>
    public let revision: UInt64
    public let terminal: RouterScenarioTerminal
    public let rejection: RouterScenarioRejectionKind?

    public init(
        state: RouterState<R>,
        revision: UInt64,
        terminal: RouterScenarioTerminal,
        rejection: RouterScenarioRejectionKind? = nil
    ) {
        self.state = state
        self.revision = revision
        self.terminal = terminal
        self.rejection = rejection
    }
}

/// Serializable meaning needed to reproduce a request through the same
/// production preparation path that originally submitted it.
public enum RouterScenarioRequestSemantics<R: Route & Codable>: Hashable, Sendable, Codable {
    /// Replays ``RouterScenarioStep/action`` as an exact ordinary request.
    case action
    /// Rebuilds a history navigation-only target when a deferred request is resumed.
    case historyNavigation(RouterState<R>)
}

/// Recorded cause for a cancelled request terminal.
///
/// A request cancellation is replayed with an explicit
/// ``RouterScenarioControl/cancel(requestID:eventIndex:)``;
/// a deferral decision is replayed by its `.resolveDeferral(..., .cancel, ...)` control.
public enum RouterScenarioCancellationOrigin: String, Hashable, Sendable, Codable {
    case none
    case request
    case deferralDecision
}

public struct RouterScenarioStep<R: Route & Codable>: Hashable, Sendable, Codable {
    public let requestID: RouterTransitionID
    public let submissionIndex: Int
    public let submissionEventIndex: Int
    public let terminalEventIndex: Int
    public let action: RouterAction<R>
    public let context: RouterTransitionContext
    public let requestSemantics: RouterScenarioRequestSemantics<R>
    public let expectedRevision: UInt64?
    public let cancellationOrigin: RouterScenarioCancellationOrigin
    public let observedState: RouterState<R>
    public let observedRevision: UInt64
    public let observedTerminal: RouterScenarioTerminal
    public let observedRejection: RouterScenarioRejectionKind?
    public let observedDeferralID: RouterDeferralID?
    public let expectation: RouterScenarioExpectation<R>?

    public init(
        requestID: RouterTransitionID = .init(rawValue: UUID()),
        submissionIndex: Int = 0,
        submissionEventIndex: Int = 0,
        terminalEventIndex: Int = 1,
        action: RouterAction<R>,
        context: RouterTransitionContext,
        requestSemantics: RouterScenarioRequestSemantics<R>? = nil,
        expectedRevision: UInt64? = nil,
        cancellationOrigin: RouterScenarioCancellationOrigin = .none,
        observedState: RouterState<R>,
        observedRevision: UInt64,
        observedTerminal: RouterScenarioTerminal,
        observedRejection: RouterScenarioRejectionKind? = nil,
        observedDeferralID: RouterDeferralID? = nil,
        expectation: RouterScenarioExpectation<R>? = nil
    ) {
        self.requestID = requestID
        self.submissionIndex = submissionIndex
        self.submissionEventIndex = submissionEventIndex
        self.terminalEventIndex = terminalEventIndex
        self.action = action
        self.context = context
        self.requestSemantics = requestSemantics ?? Self.inferSemantics(
            action: action,
            context: context
        )
        self.expectedRevision = expectedRevision
        self.cancellationOrigin = cancellationOrigin
        self.observedState = observedState
        self.observedRevision = observedRevision
        self.observedTerminal = observedTerminal
        self.observedRejection = observedRejection
        self.observedDeferralID = observedDeferralID
        self.expectation = expectation
    }

    private static func inferSemantics(
        action: RouterAction<R>,
        context: RouterTransitionContext
    ) -> RouterScenarioRequestSemantics<R> {
        if context.source == .history,
           case .apply(let plan) = action {
            return .historyNavigation(plan.state)
        }
        return .action
    }
}

/// One deterministic scheduling decision in a captured or authored replay.
/// Request IDs are logical fixture identities and are remapped to fresh
/// production transition IDs by ``RouterScenarioRunner``.
public enum RouterScenarioControl: Hashable, Sendable, Codable {
    case submit(requestID: RouterTransitionID, eventIndex: Int)
    case waitUntilStarted(requestID: RouterTransitionID, eventIndex: Int)
    case cancel(requestID: RouterTransitionID, eventIndex: Int)
    case advanceTime(nanoseconds: Int64, eventIndex: Int)
    case resolveDeferral(
        requestID: RouterTransitionID,
        deferralID: RouterDeferralID,
        resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy,
        eventIndex: Int
    )
    case awaitTerminal(requestID: RouterTransitionID, eventIndex: Int)

    public var eventIndex: Int {
        switch self {
        case .submit(_, let eventIndex),
             .waitUntilStarted(_, let eventIndex),
             .cancel(_, let eventIndex),
             .advanceTime(_, let eventIndex),
             .resolveDeferral(_, _, _, _, let eventIndex),
             .awaitTerminal(_, let eventIndex):
            eventIndex
        }
    }
}

public struct RouterScenarioCompleteness: Hashable, Sendable, Codable {
    public let unpairedRequestCount: Int
    public let droppedStepCount: Int
    public let missingExpectationCount: Int
    public let missingControlCount: Int

    public init(
        unpairedRequestCount: Int = 0,
        droppedStepCount: Int = 0,
        missingExpectationCount: Int = 0,
        missingControlCount: Int = 0
    ) {
        self.unpairedRequestCount = unpairedRequestCount
        self.droppedStepCount = droppedStepCount
        self.missingExpectationCount = missingExpectationCount
        self.missingControlCount = missingControlCount
    }

    public var isComplete: Bool {
        unpairedRequestCount == 0
            && droppedStepCount == 0
            && missingExpectationCount == 0
            && missingControlCount == 0
    }
}

/// Explicit, bounded capture session for production router requests.
///
/// Requests are emitted in submission order even when terminal events arrive
/// out of order. If unmatched correlation data reaches its internal bound,
/// capture stops and reports the discarded requests as incomplete.
@MainActor
public final class RouterScenarioRecorder<R: Route & Codable> {
    private struct PendingDeferralControl {
        let resolution: RouterDeferralResolution
        let resumeStrategy: RouterDeferralResumeStrategy
        let eventIndex: Int
    }

    private struct Terminal {
        let state: RouterState<R>
        let revision: UInt64
        let kind: RouterScenarioTerminal
        let rejection: RouterScenarioRejectionKind?
        let deferralID: RouterDeferralID?
        let eventIndex: Int
    }

    private struct SubmittedRequest {
        let observation: RouterRequestObservation<R>
        let submissionIndex: Int
        let eventIndex: Int
        let cancellationOrigin: RouterScenarioCancellationOrigin
    }

    public let initialState: RouterState<R>
    public let initialRevision: UInt64
    public let capacity: Int
    public private(set) var steps: [RouterScenarioStep<R>] = []
    public private(set) var controls: [RouterScenarioControl] = []

    private let pendingObservationCapacity: Int
    private let metadata: RouterScenarioMetadata
    private let store: RouterStore<R>
    private var requests: [RouterTransitionID: SubmittedRequest] = [:]
    private var requestOrder: [RouterTransitionID] = []
    private var terminals: [RouterTransitionID: Terminal] = [:]
    private var discardedUnpairedRequestCount = 0
    private var droppedStepCount = 0
    private var droppedControlCount = 0
    private var pairedRequestCount = 0
    private var captureWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var observationWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var requestObserverID: UUID?
    private var cancellationObserverID: UUID?
    private var eventObserverID: UUID?
    private var nextSubmissionIndex = 0
    private var nextEventIndex = 0
    private var isStopped = false
    private var pendingDeferralControls: [RouterDeferralID: PendingDeferralControl] = [:]
    private var requestCancellationOrigins: [
        RouterTransitionID: RouterScenarioCancellationOrigin
    ] = [:]

    public init(
        store: RouterStore<R>,
        capacity: Int = 256,
        metadata: RouterScenarioMetadata? = nil
    ) {
        self.store = store
        self.initialState = store.state
        self.initialRevision = store.revision
        self.capacity = max(1, capacity)
        self.pendingObservationCapacity = max(256, capacity)
        self.metadata = metadata ?? RouterScenarioMetadata(
            routeSchemaID: String(describing: R.self)
        )
        requestObserverID = store.addSynchronousRequestObserver { [weak self] request in
            self?.observe(request)
        }
        cancellationObserverID = store.addSynchronousCancellationObserver { [weak self] id in
            self?.observeCancellation(id)
        }
        eventObserverID = store.addSynchronousEventObserver { [weak self] event in
            self?.observe(event)
        }
    }

    isolated deinit {
        if let requestObserverID { store.removeSynchronousRequestObserver(requestObserverID) }
        if let cancellationObserverID {
            store.removeSynchronousCancellationObserver(cancellationObserverID)
        }
        if let eventObserverID { store.removeSynchronousEventObserver(eventObserverID) }
        captureWaiters.values.forEach { $0.continuation.resume(returning: false) }
        observationWaiters.values.forEach { $0.continuation.resume(returning: false) }
    }

    /// Stops capture and returns an honest fixture. Unfinished requests are
    /// represented by `completeness` and block source generation.
    public func stop() -> RouterScenarioFixture<R> {
        guard !isStopped else { return fixture() }
        stopObserving()
        return fixture()
    }

    /// Suspends until `count` complete request/terminal pairs are captured.
    /// Returns `false` if capture stops before reaching the count.
    public func waitUntilCaptured(_ count: Int) async -> Bool {
        if steps.count >= count { return true }
        guard !isStopped, count <= capacity else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isStopped else {
                    continuation.resume(returning: false)
                    return
                }
                captureWaiters[id] = (max(0, count), continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCaptureWaiter(id)
            }
        }
    }

    /// Suspends until `count` request/terminal pairs have been observed,
    /// including pairs deliberately dropped by the capture capacity.
    public func waitUntilObserved(_ count: Int) async -> Bool {
        if pairedRequestCount >= count { return true }
        guard !isStopped else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isStopped else {
                    continuation.resume(returning: false)
                    return
                }
                observationWaiters[id] = (max(0, count), continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelObservationWaiter(id)
            }
        }
    }

    /// Records and performs an app decision for a deferred request. Calling the
    /// store directly still executes correctly, but the recorder marks that
    /// replay as incomplete because the decision itself was not observed.
    @discardableResult
    public func resolveDeferred(
        _ id: RouterDeferralID,
        with resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy = .requireUnchangedState
    ) async -> RouterOutcome<R> {
        guard !isStopped else {
            return .rejected(
                id: RouterTransitionID(),
                state: store.state,
                revision: store.revision,
                reason: .cancelled
            )
        }
        pendingDeferralControls[id] = PendingDeferralControl(
            resolution: resolution,
            resumeStrategy: resumeStrategy,
            eventIndex: consumeEventIndex()
        )
        return await store.resolveDeferred(
            id,
            with: resolution,
            resumeStrategy: resumeStrategy
        )
    }

    /// Records a deterministic virtual-time advance before applying it.
    public func advanceTime(byNanoseconds nanoseconds: Int64, on clock: RouterTestClock) {
        guard !isStopped else { return }
        appendControl(.advanceTime(
            nanoseconds: nanoseconds,
            eventIndex: consumeEventIndex()
        ))
        clock.advance(by: .nanoseconds(nanoseconds))
    }

    public func fixture() -> RouterScenarioFixture<R> {
        .init(
            initialState: initialState,
            initialRevision: initialRevision,
            metadata: metadata,
            steps: steps,
            controls: controls,
            completeness: .init(
                unpairedRequestCount: discardedUnpairedRequestCount
                    + Set(requests.keys).union(terminals.keys).count,
                droppedStepCount: droppedStepCount,
                missingExpectationCount: steps.reduce(into: 0) {
                    if $1.expectation == nil { $0 += 1 }
                },
                missingControlCount: droppedControlCount + pendingDeferralControls.count
            )
        )
    }

    private func observe(_ request: RouterRequestObservation<R>) {
        guard !isStopped, admitPending(id: request.id) else { return }
        requestOrder.append(request.id)
        let requestEventIndex = consumeEventIndex()
        let cancellationOrigin: RouterScenarioCancellationOrigin
        if let deferralID = request.context.resumedDeferral,
           let pending = pendingDeferralControls.removeValue(forKey: deferralID) {
            cancellationOrigin = pending.resolution == .cancel ? .deferralDecision : .none
            appendControl(.resolveDeferral(
                requestID: request.id,
                deferralID: deferralID,
                resolution: pending.resolution,
                resumeStrategy: pending.resumeStrategy,
                eventIndex: pending.eventIndex
            ))
        } else {
            cancellationOrigin = .none
            if request.context.resumedDeferral != nil { droppedControlCount += 1 }
            appendControl(.submit(requestID: request.id, eventIndex: requestEventIndex))
        }
        requests[request.id] = SubmittedRequest(
            observation: request,
            submissionIndex: nextSubmissionIndex,
            eventIndex: requestEventIndex,
            cancellationOrigin: cancellationOrigin
        )
        nextSubmissionIndex += 1
        drainPairsInRequestOrder()
    }

    private func observe(_ event: RouterEvent<R>) {
        guard !isStopped else { return }
        let eventIndex = consumeEventIndex()
        let terminal: (RouterTransitionID, Terminal)?
        switch event {
        case .committed(let id, _, let after, let revision, _):
            terminal = (id, Terminal(state: after, revision: revision, kind: .applied, rejection: nil, deferralID: nil, eventIndex: eventIndex))
        case .unchanged(let id, let state, let revision, _):
            terminal = (id, Terminal(state: state, revision: revision, kind: .unchanged, rejection: nil, deferralID: nil, eventIndex: eventIndex))
        case .deferred(let id, let state, let revision, let deferral, _):
            terminal = (id, Terminal(state: state, revision: revision, kind: .deferred, rejection: nil, deferralID: deferral.id, eventIndex: eventIndex))
        case .rejected(let id, let state, let revision, let reason, _):
            terminal = (id, Terminal(state: state, revision: revision, kind: .rejected, rejection: .init(reason), deferralID: nil, eventIndex: eventIndex))
        case .started(let transition):
            appendControl(.waitUntilStarted(
                requestID: transition.id,
                eventIndex: eventIndex
            ))
            terminal = nil
        case .policyPrepared, .platformAdapted:
            terminal = nil
        }
        guard let (id, value) = terminal else { return }
        guard admitPending(id: id) else { return }
        terminals[id] = value
        appendControl(.awaitTerminal(requestID: id, eventIndex: eventIndex))
        drainPairsInRequestOrder()
    }

    private func observeCancellation(_ id: RouterTransitionID) {
        guard !isStopped, requests[id] != nil else { return }
        guard requestCancellationOrigins[id] == nil else { return }
        requestCancellationOrigins[id] = .request
        appendControl(.cancel(requestID: id, eventIndex: consumeEventIndex()))
    }

    private func admitPending(id: RouterTransitionID) -> Bool {
        let pending = Set(requests.keys).union(terminals.keys)
        guard pending.contains(id) || pending.count < pendingObservationCapacity else {
            discardedUnpairedRequestCount += pending.count + 1
            requests.removeAll()
            requestOrder.removeAll()
            terminals.removeAll()
            pendingDeferralControls.removeAll()
            requestCancellationOrigins.removeAll()
            stopObserving()
            return false
        }
        return true
    }

    private func stopObserving() {
        isStopped = true
        if let requestObserverID {
            store.removeSynchronousRequestObserver(requestObserverID)
            self.requestObserverID = nil
        }
        if let cancellationObserverID {
            store.removeSynchronousCancellationObserver(cancellationObserverID)
            self.cancellationObserverID = nil
        }
        if let eventObserverID {
            store.removeSynchronousEventObserver(eventObserverID)
            self.eventObserverID = nil
        }
        let pendingCaptureWaiters = captureWaiters.values
        captureWaiters.removeAll()
        pendingCaptureWaiters.forEach { $0.continuation.resume(returning: false) }
        let pendingObservationWaiters = observationWaiters.values
        observationWaiters.removeAll()
        pendingObservationWaiters.forEach { $0.continuation.resume(returning: false) }
    }

    private func drainPairsInRequestOrder() {
        while let id = requestOrder.first,
              requests[id] != nil,
              let terminal = terminals[id] {
            requestOrder.removeFirst()
            capture(terminal: terminal, id: id)
        }
    }

    private func capture(
        terminal: Terminal,
        id: RouterTransitionID
    ) {
        guard let submitted = requests.removeValue(forKey: id) else { return }
        terminals.removeValue(forKey: id)
        let cancellationOrigin = requestCancellationOrigins.removeValue(forKey: id)
            ?? submitted.cancellationOrigin
        pairedRequestCount += 1
        let observed = observationWaiters.filter { pairedRequestCount >= $0.value.count }
        for id in observed.keys { observationWaiters.removeValue(forKey: id) }
        observed.values.forEach { $0.continuation.resume(returning: true) }
        guard steps.count < capacity else {
            droppedStepCount += 1
            return
        }
        let requestSemantics: RouterScenarioRequestSemantics<R> =
            switch submitted.observation.semantics {
            case .action: .action
            case .historyNavigation(let target): .historyNavigation(target)
            }
        steps.append(.init(
            requestID: id,
            submissionIndex: submitted.submissionIndex,
            submissionEventIndex: submitted.eventIndex,
            terminalEventIndex: terminal.eventIndex,
            action: submitted.observation.action,
            context: submitted.observation.context,
            requestSemantics: requestSemantics,
            expectedRevision: submitted.observation.expectedRevision,
            cancellationOrigin: cancellationOrigin,
            observedState: terminal.state,
            observedRevision: terminal.revision,
            observedTerminal: terminal.kind,
            observedRejection: terminal.rejection,
            observedDeferralID: terminal.deferralID
        ))
        let ready = captureWaiters.filter { steps.count >= $0.value.count }
        for id in ready.keys { captureWaiters.removeValue(forKey: id) }
        ready.values.forEach { $0.continuation.resume(returning: true) }
    }

    private func cancelCaptureWaiter(_ id: UUID) {
        captureWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    private func cancelObservationWaiter(_ id: UUID) {
        observationWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    private func consumeEventIndex() -> Int {
        defer { nextEventIndex += 1 }
        return nextEventIndex
    }

    private func appendControl(_ control: RouterScenarioControl) {
        guard controls.count < capacity * 4 else {
            droppedControlCount += 1
            return
        }
        controls.append(control)
    }
}
