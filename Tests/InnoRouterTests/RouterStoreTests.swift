import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

@Suite("RouterStore")
struct RouterStoreTests {
    private enum RouteFixture: String, Route, Codable {
        case home
        case detail
        case settings
    }

    @MainActor
    private final class EventRecorder {
        var events: [RouterEvent<RouteFixture>] = []
        var policyContexts: [RouterTransitionContext] = []
        var downstreamPreparations = 0
    }

    @MainActor
    private final class NonCooperativePolicyGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        var isWaiting = false

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
                let waiters = enteredWaiters
                enteredWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        func waitUntilEntered() async {
            if isWaiting { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            continuation?.resume()
            continuation = nil
            isWaiting = false
        }
    }

    @Test("One action commits one complete observable state")
    @MainActor
    func commitsAtomically() async {
        let recorder = EventRecorder()
        let store = RouterStore<RouteFixture>(
            configuration: .init { event in
                recorder.events.append(event)
            }
        )

        let outcome = await store.perform(.push(.detail))

        #expect(store.state.root == .stack(path: [.detail]))
        #expect(store.revision == 1)
        guard case .applied(let id, let before, let after, let revision) = outcome else {
            Issue.record("Expected applied outcome")
            return
        }
        #expect(before.root == .stack())
        #expect(after == store.state)
        #expect(revision == 1)
        #expect(recorder.events.count == 2)
        guard case .started(let transition) = recorder.events[0],
              case .committed(let committedID, _, _, _, _) = recorder.events[1] else {
            Issue.record("Expected started and committed events")
            return
        }
        #expect(transition.id == id)
        #expect(committedID == id)
    }

    @Test("Policy rejection leaves state and revision untouched")
    @MainActor
    func policyRejection() async {
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "authentication") { _ in
                        .reject("sign-in required")
                    }
                ]
            )
        )

        let outcome = await store.perform(.push(.settings))

        #expect(store.state.root == .stack())
        #expect(store.revision == 0)
        guard case .rejected(_, _, _, let reason) = outcome else {
            Issue.record("Expected rejected outcome")
            return
        }
        #expect(
            reason == .policy(
                name: "authentication",
                message: "sign-in required"
            )
        )
    }

    @Test("Concurrent requests serialize in FIFO order by default", arguments: 0..<100)
    @MainActor
    func serializedRequests(_: Int) async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ]
            )
        )
        var iterator = store.events.makeAsyncIterator()
        let first = Task { @MainActor in
            await store.perform(.push(.detail))
        }
        guard case .started = await iterator.next() else {
            Issue.record("Expected first transition to start")
            continuation.finish()
            return
        }

        let second = Task { @MainActor in
            await store.perform(.push(.settings))
        }
        await Task.yield()
        #expect(store.state.root == .stack())

        continuation.yield()
        continuation.finish()
        _ = await first.value
        guard case .applied = await second.value else {
            Issue.record("Expected queued transition to apply")
            return
        }
        #expect(store.state.root == .stack(path: [.detail, .settings]))
    }

    @Test("A bounded queue rejects the newest request by default", arguments: 0..<100)
    @MainActor
    func queueRejectsNewestOverflow(_: Int) async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ],
                maximumPendingRequestCount: 1
            )
        )
        var events = store.events.makeAsyncIterator()
        let active = Task { @MainActor in await store.perform(.push(.home)) }
        guard case .started = await events.next() else {
            Issue.record("Expected active request")
            continuation.finish()
            return
        }
        let pending = Task { @MainActor in await store.perform(.push(.detail)) }
        await Task.yield()

        let overflow = await store.perform(.push(.settings))
        guard case .rejected(_, _, _, let reason) = overflow else {
            Issue.record("Expected queue overflow rejection")
            continuation.finish()
            return
        }
        #expect(reason == .queueOverflow(limit: 1))

        continuation.yield()
        continuation.yield()
        continuation.finish()
        _ = await active.value
        _ = await pending.value
        #expect(store.state.root == .stack(path: [.home, .detail]))
    }

    @Test("A bounded queue can discard its oldest pending request", arguments: 0..<100)
    @MainActor
    func queueDiscardsOldestOverflow(_: Int) async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ],
                maximumPendingRequestCount: 1,
                requestOverflowStrategy: .discardOldest
            )
        )
        var events = store.events.makeAsyncIterator()
        let active = Task { @MainActor in await store.perform(.push(.home)) }
        guard case .started = await events.next() else {
            Issue.record("Expected active request")
            continuation.finish()
            return
        }
        let discarded = Task { @MainActor in await store.perform(.push(.detail)) }
        await Task.yield()
        let replacement = Task { @MainActor in await store.perform(.push(.settings)) }

        guard case .rejected(_, _, _, let reason) = await discarded.value else {
            Issue.record("Expected oldest pending request to be discarded")
            continuation.finish()
            return
        }
        #expect(reason == .queueOverflow(limit: 1))

        continuation.yield()
        continuation.yield()
        continuation.finish()
        _ = await active.value
        guard case .applied = await replacement.value else {
            Issue.record("Expected replacement request to apply")
            return
        }
        #expect(store.state.root == .stack(path: [.home, .settings]))
    }

    @Test("Latest keyed request replaces only an older pending duplicate", arguments: 0..<100)
    @MainActor
    func replacePendingRequest(_: Int) async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ]
            )
        )
        var iterator = store.events.makeAsyncIterator()
        let active = Task { @MainActor in
            await store.perform(.push(.home))
        }
        guard case .started = await iterator.next() else {
            Issue.record("Expected active transition")
            continuation.finish()
            return
        }

        let context = RouterTransitionContext(
            requestKey: "selection",
            coalescing: .replacePending
        )
        let replaced = Task { @MainActor in
            await store.perform(.push(.settings), context: context)
        }
        await Task.yield()
        let replacement = Task { @MainActor in
            await store.perform(.push(.detail), context: context)
        }
        let replacedOutcome = await replaced.value

        continuation.yield()
        continuation.finish()
        _ = await active.value
        let replacementOutcome = await replacement.value

        guard case .rejected(_, _, _, let reason) = replacedOutcome else {
            Issue.record("Expected superseded pending request")
            return
        }
        #expect(reason == .superseded(replacementTransition: replacementOutcome.id))
        #expect(store.state.root == .stack(path: [.home, .detail]))
    }

    @Test("Keep-first coalescing rejects a duplicate of the active request", arguments: 0..<100)
    @MainActor
    func keepFirstRequest(_: Int) async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let context = RouterTransitionContext(
            requestKey: "primary-action",
            coalescing: .keepFirst
        )
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ]
            )
        )
        var iterator = store.events.makeAsyncIterator()
        let active = Task { @MainActor in
            await store.perform(.push(.detail), context: context)
        }
        guard case .started(let transition) = await iterator.next() else {
            Issue.record("Expected active transition")
            continuation.finish()
            return
        }

        let duplicate = await store.perform(.push(.settings), context: context)
        guard case .rejected(_, _, _, let reason) = duplicate else {
            Issue.record("Expected coalesced duplicate")
            continuation.finish()
            return
        }
        #expect(reason == .coalesced(existingTransition: transition.id))

        continuation.yield()
        continuation.finish()
        _ = await active.value
        #expect(store.state.root == .stack(path: [.detail]))
    }

    @Test("Deferred guard releases the lane and resumes through remaining policies")
    @MainActor
    func deferredGuardResume() async {
        let deferralID = RouterDeferralID()
        let recorder = EventRecorder()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "confirmation") { transition in
                        if transition.action == .push(.detail),
                           transition.context.resumedDeferral == nil {
                            return .deferRequest(deferralID)
                        }
                        return .allow
                    },
                    RouterPolicy(name: "downstream") { _ in
                        recorder.downstreamPreparations += 1
                        return .allow
                    },
                ]
            )
        )

        let deferred = await store.perform(.push(.detail))
        guard case .deferred(_, _, _, let metadata) = deferred else {
            Issue.record("Expected deferred transition")
            return
        }
        #expect(metadata.id == deferralID)
        #expect(store.deferredTransitions == [metadata])
        #expect(store.state.root == .stack())

        guard case .applied = await store.perform(.push(.home)) else {
            Issue.record("Expected unrelated request to use the released lane")
            return
        }
        let resumed = await store.resumeDeferred(
            deferralID,
            strategy: .rebaseOnCurrentState
        )

        guard case .applied = resumed else {
            Issue.record("Expected rebased deferred transition to apply")
            return
        }
        #expect(store.state.root == .stack(path: [.home, .detail]))
        #expect(store.deferredTransitions.isEmpty)
        #expect(recorder.downstreamPreparations == 2)
    }

    @Test("Deferred guard requires unchanged canonical state by default", arguments: 0..<100)
    @MainActor
    func deferredGuardStaleState(_: Int) async {
        let deferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "confirmation") { transition in
                        transition.action == .push(.detail)
                            ? .deferRequest(deferralID)
                            : .allow
                    }
                ]
            )
        )

        _ = await store.perform(.push(.detail))
        _ = await store.perform(.push(.home))
        let resumed = await store.resumeDeferred(deferralID)

        guard case .rejected(_, _, _, let reason) = resumed else {
            Issue.record("Expected stale deferred transition rejection")
            return
        }
        #expect(reason == .staleState(expectedRevision: 0, actualRevision: 1))
        #expect(store.state.root == .stack(path: [.home]))
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("The deferral registry rejects overflow and cancels retained work")
    @MainActor
    func boundedDeferrals() async {
        let detailID = RouterDeferralID()
        let settingsID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { transition in
                        switch transition.action {
                        case .push(.detail): .deferRequest(detailID)
                        case .push(.settings): .deferRequest(settingsID)
                        default: .allow
                        }
                    }
                ],
                deferrals: .init(maximumPendingCount: 1)
            )
        )

        guard case .deferred = await store.perform(.push(.detail)) else {
            Issue.record("Expected first deferral")
            return
        }
        let overflow = await store.perform(.push(.settings))
        guard case .rejected(_, _, _, let overflowReason) = overflow else {
            Issue.record("Expected bounded deferral rejection")
            return
        }
        #expect(overflowReason == .deferralCapacityExceeded(limit: 1))

        let cancelled = await store.cancelDeferred(detailID)
        #expect(store.deferredTransitions.isEmpty)
        guard case .rejected(_, _, _, let cancellationReason) = cancelled else {
            Issue.record("Expected explicit cancellation rejection")
            return
        }
        #expect(cancellationReason == .cancelled)
    }

    @Test("Deferral overflow can cancel the oldest unresolved request")
    @MainActor
    func deferralCancelsOldest() async {
        let detailID = RouterDeferralID()
        let settingsID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { transition in
                        switch transition.action {
                        case .push(.detail): .deferRequest(detailID)
                        case .push(.settings): .deferRequest(settingsID)
                        default: .allow
                        }
                    }
                ],
                deferrals: .init(
                    maximumPendingCount: 1,
                    overflowStrategy: .cancelOldest
                )
            )
        )

        _ = await store.perform(.push(.detail))
        guard case .deferred = await store.perform(.push(.settings)) else {
            Issue.record("Expected newest deferral to replace the oldest")
            return
        }
        #expect(store.deferredTransitions.map(\.id) == [settingsID])
        guard case .rejected(_, _, _, let reason) = await store.resumeDeferred(detailID) else {
            Issue.record("Expected evicted deferral to be absent")
            return
        }
        #expect(reason == .deferralNotFound(detailID))
    }

    @Test("A deferred result presentation remains awaitable after guard approval")
    @MainActor
    func deferredPresentationResult() async throws {
        let deferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "confirmation") { transition in
                        if case .present = transition.action {
                            return .deferRequest(deferralID)
                        }
                        return .allow
                    }
                ]
            )
        )
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        for _ in 0..<20 where store.deferredTransitions.isEmpty {
            await Task.yield()
        }

        guard case .applied = await store.resumeDeferred(deferralID) else {
            Issue.record("Expected deferred presentation to commit")
            return
        }
        try await store.finishPresentation(returning: "approved")
        #expect(await result.value == .value("approved"))
    }

    @Test("A typed completion keeps ownership across repeated deferrals")
    @MainActor
    func repeatedDeferredPresentationCompletion() async throws {
        let firstDeferralID = RouterDeferralID()
        let secondDeferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "first-confirmation") { transition in
                        guard case .dismissPresentation = transition.action,
                              transition.context.resumedDeferral == nil else {
                            return .allow
                        }
                        return .deferRequest(firstDeferralID)
                    },
                    RouterPolicy(name: "second-confirmation") { transition in
                        guard case .dismissPresentation = transition.action,
                              transition.context.resumedDeferral == firstDeferralID else {
                            return .allow
                        }
                        return .deferRequest(secondDeferralID)
                    },
                ]
            )
        )
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        await drainMainActor()

        await #expect(
            throws: RouterPresentationCompletionError.dismissalDeferred(firstDeferralID)
        ) {
            try await store.finishPresentation(returning: "approved")
        }
        guard case .deferred(_, _, _, let secondDeferral) = await store.resumeDeferred(
            firstDeferralID
        ) else {
            Issue.record("Expected repeated deferral")
            return
        }
        #expect(secondDeferral.id == secondDeferralID)
        guard case .applied = await store.resumeDeferred(secondDeferralID) else {
            Issue.record("Expected deferred dismissal to commit")
            return
        }
        #expect(await result.value == .value("approved"))
        #expect(store.state == .rootStack)
    }

    @Test("Rejecting a deferred presentation completes its awaiting caller")
    @MainActor
    func rejectedDeferredPresentation() async {
        let deferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "confirmation") { transition in
                        if case .present = transition.action {
                            return .deferRequest(deferralID)
                        }
                        return .allow
                    }
                ]
            )
        )
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        for _ in 0..<20 where store.deferredTransitions.isEmpty {
            await Task.yield()
        }

        _ = await store.resolveDeferred(deferralID, with: .reject("declined"))
        #expect(
            await result.value == .rejected(
                .policy(name: "confirmation", message: "declined")
            )
        )
        #expect(store.state.root == .stack())
    }

    @Test("Busy rejection remains an explicit scheduling policy", arguments: 0..<100)
    @MainActor
    func busyRejection(_: Int) async {
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ],
                schedulingPolicy: .rejectWhileBusy
            )
        )
        var iterator = store.events.makeAsyncIterator()
        let first = Task { @MainActor in
            await store.perform(.push(.detail))
        }
        guard case .started(let transition) = await iterator.next() else {
            Issue.record("Expected first transition to start")
            continuation.finish()
            return
        }

        let second = await store.perform(.push(.settings))
        guard case .rejected(_, _, _, let reason) = second else {
            Issue.record("Expected concurrent rejection")
            continuation.finish()
            return
        }
        #expect(reason == .busy(activeTransition: transition.id))

        continuation.yield()
        continuation.finish()
        _ = await first.value
    }

    @Test("Cancelling a suspended request never commits its candidate")
    @MainActor
    func cancellation() async {
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "slow") { _ in
                        try? await Task.sleep(for: .seconds(30))
                        return .allow
                    }
                ]
            )
        )
        var iterator = store.events.makeAsyncIterator()
        let task = Task { @MainActor in
            await store.perform(.push(.detail))
        }
        guard case .started = await iterator.next() else {
            Issue.record("Expected transition to start")
            return
        }

        task.cancel()
        let outcome = await task.value

        #expect(store.state.root == .stack())
        #expect(store.revision == 0)
        guard case .rejected(_, _, _, let reason) = outcome else {
            Issue.record("Expected cancelled rejection")
            return
        }
        #expect(reason == .cancelled)
    }

    @Test("Cancellation wins over a non-cooperative policy timeout", arguments: 0..<100)
    @MainActor
    func cancellationBeforePolicyTimeout(_: Int) async {
        let gate = NonCooperativePolicyGate()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "non-cooperative") { _ in
                        await gate.wait()
                        return .allow
                    }
                ],
                policyTimeout: .seconds(30)
            )
        )
        var iterator = store.events.makeAsyncIterator()
        let task = Task { @MainActor in
            await store.perform(.push(.detail))
        }
        guard case .started = await iterator.next() else {
            Issue.record("Expected transition to start")
            return
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        task.cancel()
        let outcome = await task.value
        gate.release()

        guard case .rejected(_, _, _, let reason) = outcome else {
            Issue.record("Expected cancelled rejection")
            return
        }
        #expect(reason == .cancelled)
        #expect(store.state.root == .stack())
        #expect(store.revision == 0)
    }

    @Test("No-op action has a terminal outcome without advancing revision")
    @MainActor
    func unchanged() async {
        let store = RouterStore<RouteFixture>()

        let outcome = await store.perform(.pop(count: 0))

        guard case .unchanged(_, let state, let revision) = outcome else {
            Issue.record("Expected unchanged outcome")
            return
        }
        #expect(state == store.state)
        #expect(revision == 0)
        #expect(store.revision == 0)
    }

    @Test("Awaited presentation resumes with the exact returned value")
    @MainActor
    func presentationResult() async throws {
        let store = RouterStore<RouteFixture>()
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        await drainMainActor()

        try await store.finishPresentation(returning: "saved")

        #expect(await result.value == .value("saved"))
        #expect(store.state.root == .stack())
        #expect(store.revision == 2)
    }

    @Test("Typed presentation request validates both result and active route")
    @MainActor
    func typedPresentationRequest() async throws {
        let store = RouterStore<RouteFixture>()
        let request = RouterPresentationRequest<RouteFixture, String>(route: .detail)
        let result = Task { @MainActor in
            await store.present(request)
        }
        await drainMainActor()

        let wrongRequest = RouterPresentationRequest<RouteFixture, String>(route: .settings)
        guard case .stack(let stack) = store.state.root,
              let presentationID = stack.presentation?.id else {
            Issue.record("Expected active presentation")
            return
        }
        await #expect(
            throws: RouterPresentationCompletionError.presentationRouteMismatch(presentationID)
        ) {
            try await store.finishPresentation(wrongRequest, returning: "wrong")
        }

        try await store.finishPresentation(request, returning: "saved")
        #expect(await result.value == .value("saved"))
    }

    @Test("A queued completion cannot dismiss a replacement presentation")
    @MainActor
    func presentationCompletionUsesExactIdentity() async throws {
        let gate = NonCooperativePolicyGate()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "replacement-gate") { transition in
                        guard case .apply = transition.action else { return .allow }
                        await gate.wait()
                        return .allow
                    }
                ]
            )
        )
        let request = RouterPresentationRequest<RouteFixture, String>(route: .detail)
        let awaiting = Task { @MainActor in await store.present(request) }
        await drainMainActor()
        guard case .stack(let initialStack) = store.state.root,
              let originalID = initialStack.presentation?.id else {
            Issue.record("Expected original presentation")
            return
        }

        let replacementID = UUID()
        let replacementState = try RouterState<RouteFixture>(
            root: .stack(
                presentation: .init(id: replacementID, route: .home, style: .sheet)
            )
        )
        let replacement = Task { @MainActor in
            await store.perform(.apply(.init(state: replacementState)))
        }
        while !gate.isWaiting { await Task.yield() }
        let completion = Task { @MainActor in
            try await store.finishPresentation(request, returning: "stale")
        }
        await drainMainActor()

        gate.release()
        guard case .applied = await replacement.value else {
            Issue.record("Expected replacement to apply")
            return
        }
        await #expect(
            throws: RouterPresentationCompletionError.dismissalRejected(
                .mutation(.presentationIdentityMismatch(
                    scope: .root,
                    expected: originalID,
                    actual: replacementID
                ))
            )
        ) {
            try await completion.value
        }
        #expect(await awaiting.value == .dismissed)
        #expect(store.state == replacementState)
        #expect(store.revision == 2)
    }

    @Test("Cancelling a presentation cannot dismiss its queued replacement")
    @MainActor
    func presentationCancellationUsesExactIdentity() async throws {
        let gate = NonCooperativePolicyGate()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "replacement-gate") { transition in
                        guard case .apply = transition.action else { return .allow }
                        await gate.wait()
                        return .allow
                    }
                ]
            )
        )
        let awaiting = Task { @MainActor in
            await store.present(.home, expecting: String.self)
        }
        var events = store.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .committed(_, _, _, 1, _) = event { break }
        }
        guard case .stack(let originalStack) = store.state.root,
              originalStack.presentation != nil else {
            Issue.record("Expected the original presentation")
            return
        }

        let replacementID = UUID()
        let replacementState = try RouterState<RouteFixture>(
            root: .stack(
                presentation: .init(id: replacementID, route: .detail, style: .sheet)
            )
        )
        let replacement = Task { @MainActor in
            await store.perform(.apply(.init(state: replacementState)))
        }
        await gate.waitUntilEntered()
        var observations = store.requestObservations.makeAsyncIterator()
        awaiting.cancel()
        while let observation = await observations.next() {
            if observation.action == .dismissPresentation { break }
        }

        gate.release()
        guard case .applied = await replacement.value else {
            Issue.record("Expected the replacement to commit")
            return
        }
        _ = await store.perform(.popToRoot)

        #expect(await awaiting.value == .cancelled)
        #expect(store.state == replacementState)
        #expect(store.revision == 2)
    }

    @Test("A cancelled presentation cannot commit while its deferral is resuming")
    @MainActor
    func cancelledPresentationCannotCommitWhileResuming() async {
        let gate = NonCooperativePolicyGate()
        let deferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { transition in
                        if case .present = transition.action,
                           transition.context.resumedDeferral == nil {
                            return .deferRequest(deferralID)
                        }
                        return .allow
                    },
                    RouterPolicy(name: "resume-gate") { transition in
                        guard case .present = transition.action else { return .allow }
                        await gate.wait()
                        return .allow
                    }
                ]
            )
        )
        let awaiting = Task { @MainActor in
            await store.present(.home, expecting: String.self)
        }
        var events = store.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .deferred = event { break }
        }

        let resuming = Task { @MainActor in
            await store.resumeDeferred(deferralID)
        }
        await gate.waitUntilEntered()
        awaiting.cancel()
        #expect(await awaiting.value == .cancelled)

        gate.release()
        guard case .rejected(_, _, _, .cancelled) = await resuming.value else {
            Issue.record("Expected the resumed presentation to be cancelled")
            return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("Presentation cancellation releases an active resumed policy lane")
    @MainActor
    func presentationCancellationReleasesResumedPolicyLane() async {
        let gate = NonCooperativePolicyGate()
        let deferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { transition in
                        if case .present = transition.action,
                           transition.context.resumedDeferral == nil {
                            return .deferRequest(deferralID)
                        }
                        return .allow
                    },
                    RouterPolicy(name: "resume-gate") { transition in
                        guard case .present = transition.action else { return .allow }
                        await gate.wait()
                        return .allow
                    },
                ],
                schedulingPolicy: .rejectWhileBusy
            )
        )
        let awaiting = Task { @MainActor in
            await store.present(.home, expecting: String.self)
        }
        var events = store.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .deferred = event { break }
        }
        let resuming = Task { @MainActor in
            await store.resumeDeferred(deferralID)
        }
        await gate.waitUntilEntered()

        awaiting.cancel()
        #expect(await awaiting.value == .cancelled)
        let following = await store.perform(.push(.detail))

        gate.release()
        guard case .rejected(_, _, _, .cancelled) = await resuming.value else {
            Issue.record("Expected the resumed request to be cancelled")
            return
        }
        guard case .applied = following else {
            Issue.record("Expected cancellation to release the execution lane, got \(following)")
            return
        }
        #expect(store.state == .rootStack(path: [.detail]))
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("A late policy deferral cannot revive a cancelled presentation")
    @MainActor
    func cancelledPresentationCannotBeRedeferred() async {
        let gate = NonCooperativePolicyGate()
        let firstDeferralID = RouterDeferralID()
        let secondDeferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "first") { transition in
                transition.context.resumedDeferral == nil
                    ? .deferRequest(firstDeferralID)
                    : .allow
            },
            RouterPolicy(name: "late-deferral") { _ in
                await gate.wait()
                return .deferRequest(secondDeferralID)
            },
        ]))
        let awaiting = Task { @MainActor in
            await store.present(.home, expecting: String.self)
        }
        var events = store.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .deferred = event { break }
        }
        let resuming = Task { @MainActor in
            await store.resumeDeferred(firstDeferralID)
        }
        await gate.waitUntilEntered()

        awaiting.cancel()
        #expect(await awaiting.value == .cancelled)
        gate.release()

        guard case .rejected(_, _, _, .cancelled) = await resuming.value else {
            Issue.record("Expected cancellation instead of a second deferral")
            return
        }
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("A native dismissal cannot remove a replacement presentation")
    @MainActor
    func nativeDismissalUsesExactPresentationIdentity() async throws {
        let gate = NonCooperativePolicyGate()
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "replacement-gate") { transition in
                guard case .apply = transition.action else { return .allow }
                await gate.wait()
                return .allow
            },
        ]))
        let original = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        guard case .applied = await store.perform(.present(original)) else {
            Issue.record("Expected the original presentation")
            return
        }
        let binding = makeRouterPresentationBinding(scope: store.scope(), style: .sheet)
        #expect(binding.wrappedValue?.id == original.id)
        let replacement = RouterPresentation<RouteFixture>(route: .detail, style: .sheet)
        let replacementState = try RouterState<RouteFixture>(
            root: .stack(presentation: replacement)
        )
        let replacing = Task { @MainActor in
            await store.perform(.apply(.init(state: replacementState)))
        }
        await gate.waitUntilEntered()
        var observations = store.requestObservations.makeAsyncIterator()

        binding.wrappedValue = nil
        while let observation = await observations.next() {
            if observation.action == .dismissPresentation { break }
        }
        gate.release()
        guard case .applied = await replacing.value else {
            Issue.record("Expected the replacement presentation")
            return
        }
        _ = await store.perform(.popToRoot)

        #expect(store.state == replacementState)
        #expect(store.revision == 2)
    }

    @Test("Stale native dismissal is scoped by presentation identity", arguments: 0..<3)
    @MainActor
    func nativeDismissalIsScopedByPresentationIdentity(_ scopeIndex: Int) async throws {
        let windowID = UUID()
        let path: RouterScopePath = switch scopeIndex {
        case 0: .root
        case 1: .root.appending("home")
        default: .window(windowID)
        }
        let original = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        let replacement = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        func state(_ presentation: RouterPresentation<RouteFixture>) throws -> RouterState<RouteFixture> {
            switch scopeIndex {
            case 0:
                return try RouterState(root: .stack(presentation: presentation))
            case 1:
                let tabs = try RouterContainerState<RouteFixture>(
                    style: .tabs,
                    selection: "home",
                    branches: [
                        .init(id: "home", node: .stack(presentation: presentation)),
                        .init(id: "settings"),
                    ]
                )
                return try RouterState(root: .container(tabs))
            default:
                return try RouterState(
                    windows: [
                        .init(
                            id: windowID,
                            route: .settings,
                            node: .stack(presentation: presentation)
                        ),
                    ]
                )
            }
        }
        let store = RouterStore(initialState: try state(original))
        let binding = makeRouterPresentationBinding(scope: store.scope(at: path), style: .sheet)
        let replacementState = try state(replacement)
        guard case .applied = await store.perform(.apply(.init(state: replacementState))) else {
            Issue.record("Expected replacement presentation")
            return
        }
        var observations = store.requestObservations.makeAsyncIterator()

        binding.wrappedValue = nil
        guard let first = await observations.next() else {
            Issue.record("Expected native dismissal request")
            return
        }
        binding.wrappedValue = nil
        guard let second = await observations.next() else {
            Issue.record("Expected duplicate native dismissal request")
            return
        }
        _ = await store.perform(.popToRoot)

        #expect(first.context.source == .system)
        #expect(second.context.source == .system)
        #expect(store.state == replacementState)
        #expect(store.revision == 1)
    }

    @Test("Every presentation style adapts without losing dismissal identity")
    @MainActor
    func adaptedPresentationStylesPreserveDismissalIdentity() async throws {
        for style in [
            RouterPresentationStyle.sheet,
            .fullScreenCover,
            .popover,
        ] {
            let original = RouterPresentation<RouteFixture>(route: .home, style: style)
            let replacement = RouterPresentation<RouteFixture>(route: .detail, style: style)
            let store = RouterStore(
                initialState: try RouterState<RouteFixture>(
                    root: .stack(presentation: original)
                )
            )
            let effectiveStyle = RouterPlatformCapabilities.current
                .effectivePresentationStyle(for: style)
            let binding = makeRouterPresentationBinding(
                scope: store.scope(),
                style: effectiveStyle
            )
            let replacementState = try RouterState<RouteFixture>(
                root: .stack(presentation: replacement)
            )
            _ = await store.perform(.apply(.init(state: replacementState)))
            var observations = store.requestObservations.makeAsyncIterator()

            binding.wrappedValue = nil
            guard let observation = await observations.next() else {
                Issue.record("Expected adapted native dismissal request")
                return
            }
            _ = await store.perform(.popToRoot)

            #expect(observation.context.source == .system)
            #expect(store.state == replacementState)
            #expect(store.revision == 1)
        }
    }

    @Test("A deferred native dismissal cannot remove a replacement presentation")
    @MainActor
    func deferredNativeDismissalUsesExactIdentity() async throws {
        let deferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(configuration: .init(policies: [
            RouterPolicy(name: "native-dismissal") { transition in
                transition.action == .dismissPresentation
                    && transition.context.source == .system
                    && transition.context.resumedDeferral == nil
                    ? .deferRequest(deferralID)
                    : .allow
            },
        ]))
        let original = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        _ = await store.perform(.present(original))
        let binding = makeRouterPresentationBinding(scope: store.scope(), style: .sheet)
        var events = store.events.makeAsyncIterator()
        binding.wrappedValue = nil
        while let event = await events.next() {
            if case .deferred(_, _, _, let deferred, _) = event,
               deferred.id == deferralID { break }
        }
        let replacement = RouterPresentation<RouteFixture>(route: .detail, style: .sheet)
        let replacementState = try RouterState<RouteFixture>(
            root: .stack(presentation: replacement)
        )
        _ = await store.perform(.apply(.init(state: replacementState)))

        let outcome = await store.resumeDeferred(deferralID, strategy: .rebaseOnCurrentState)

        guard case .rejected(
            _, _, _, .mutation(.presentationIdentityMismatch(
                scope: .root,
                expected: original.id,
                actual: replacement.id
            ))
        ) = outcome else {
            Issue.record("Expected the stale dismissal to be rejected")
            return
        }
        #expect(store.state == replacementState)
        #expect(store.revision == 2)
    }

    @Test("Stale native dismissal preserves a replacement typed waiter")
    @MainActor
    func staleNativeDismissalPreservesTypedWaiter() async throws {
        let store = RouterStore<RouteFixture>()
        let original = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        _ = await store.perform(.present(original))
        let binding = makeRouterPresentationBinding(scope: store.scope(), style: .sheet)
        _ = await store.perform(.dismissPresentation)
        var events = store.events.makeAsyncIterator()
        let awaiting = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        while let event = await events.next() {
            if case .committed(_, _, _, 3, _) = event { break }
        }
        var observations = store.requestObservations.makeAsyncIterator()
        binding.wrappedValue = nil
        _ = await observations.next()
        _ = await store.perform(.popToRoot)

        try await store.finishPresentation(returning: "saved")

        #expect(await awaiting.value == .value("saved"))
        #expect(store.revision == 4)
    }

    @Test("A stale native detent callback cannot mutate a replacement presentation")
    @MainActor
    func staleNativeDetentUsesExactIdentity() async throws {
        let options = RouterPresentationOptions(
            detents: [.medium, .large],
            selectedDetent: .medium
        )
        let original = RouterPresentation<RouteFixture>(
            route: .home,
            style: .sheet,
            options: options
        )
        let replacement = RouterPresentation<RouteFixture>(
            route: .home,
            style: .sheet,
            options: options
        )
        let store = RouterStore(
            initialState: try RouterState<RouteFixture>(
                root: .stack(presentation: original)
            )
        )
        let binding = makeRouterPresentationDetentBinding(
            scope: store.scope(),
            presentation: original
        )
        let replacementState = try RouterState<RouteFixture>(
            root: .stack(presentation: replacement)
        )
        _ = await store.perform(.apply(.init(state: replacementState)))
        var observations = store.requestObservations.makeAsyncIterator()

        binding.wrappedValue = .large
        guard let observation = await observations.next() else {
            Issue.record("Expected native detent request")
            return
        }
        _ = await store.perform(.popToRoot)

        #expect(observation.context.source == .system)
        #expect(store.state == replacementState)
        #expect(store.revision == 1)
    }

    @Test("Native dismissal preserves policy rejection and reconciles the binding")
    @MainActor
    func nativeDismissalPolicyRejectionReconcilesBinding() async throws {
        let original = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        let store = RouterStore(
            initialState: try RouterState<RouteFixture>(
                root: .stack(presentation: original)
            ),
            configuration: .init(policies: [
                RouterPolicy(name: "keep-modal") { transition in
                    transition.action == .dismissPresentation
                        && transition.context.source == .system
                        ? .reject("required")
                        : .allow
                },
            ])
        )
        let scope = store.scope()
        let binding = makeRouterPresentationBinding(scope: scope, style: .sheet)
        var events = store.events.makeAsyncIterator()

        binding.wrappedValue = nil
        while let event = await events.next() {
            if case .rejected(_, _, _, _, let context) = event,
               context.source == .system { break }
        }

        #expect(store.state.root == .stack(presentation: original))
        #expect(store.revision == 0)
        #expect(scope.reconciliationRevision == 1)
        #expect(binding.wrappedValue == original)
    }

    @Test("Native dismissal commits the matching presentation exactly once")
    @MainActor
    func nativeDismissalCommitsMatchingPresentation() async throws {
        let original = RouterPresentation<RouteFixture>(route: .home, style: .sheet)
        let store = RouterStore(
            initialState: try RouterState<RouteFixture>(
                root: .stack(presentation: original)
            )
        )
        let binding = makeRouterPresentationBinding(scope: store.scope(), style: .sheet)
        var events = store.events.makeAsyncIterator()

        binding.wrappedValue = nil
        while let event = await events.next() {
            if case .committed(_, _, _, _, let context) = event,
               context.source == .system { break }
        }
        binding.wrappedValue = nil
        _ = await store.perform(.popToRoot)

        #expect(store.state.root == .stack())
        #expect(store.revision == 1)
    }

    @Test("Presentation cancellation follows ownership across repeated deferrals")
    @MainActor
    func cancelledPresentationAfterRepeatedDeferral() async {
        let firstDeferralID = RouterDeferralID()
        let secondDeferralID = RouterDeferralID()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "first-confirmation") { transition in
                        guard case .present = transition.action,
                              transition.context.resumedDeferral == nil else {
                            return .allow
                        }
                        return .deferRequest(firstDeferralID)
                    },
                    RouterPolicy(name: "second-confirmation") { transition in
                        guard case .present = transition.action,
                              transition.context.resumedDeferral == firstDeferralID else {
                            return .allow
                        }
                        return .deferRequest(secondDeferralID)
                    },
                ]
            )
        )
        let awaiting = Task { @MainActor in
            await store.present(.home, expecting: String.self)
        }
        var events = store.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .deferred(_, _, _, let metadata, _) = event,
               metadata.id == firstDeferralID {
                break
            }
        }

        guard case .deferred(_, _, _, let secondDeferral) = await store.resumeDeferred(
            firstDeferralID
        ) else {
            Issue.record("Expected the presentation to defer a second time")
            return
        }
        #expect(secondDeferral.id == secondDeferralID)

        awaiting.cancel()
        #expect(await awaiting.value == .cancelled)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.deferredTransitions.isEmpty)
        guard case .rejected(_, _, _, .deferralNotFound(secondDeferralID)) =
                await store.resumeDeferred(secondDeferralID) else {
            Issue.record("Expected cancellation to consume the newest deferral")
            return
        }
    }

    @Test("Only one typed completion may be pending for a presentation")
    @MainActor
    func duplicatePresentationCompletionIsRejected() async throws {
        let gate = NonCooperativePolicyGate()
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "dismissal-gate") { transition in
                        guard case .dismissPresentation = transition.action else { return .allow }
                        await gate.wait()
                        return .allow
                    }
                ]
            )
        )
        let awaiting = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        await drainMainActor()
        guard case .stack(let stack) = store.state.root,
              let presentationID = stack.presentation?.id else {
            Issue.record("Expected active presentation")
            return
        }
        let first = Task { @MainActor in
            try await store.finishPresentation(returning: "first")
        }
        while !gate.isWaiting { await Task.yield() }

        await #expect(
            throws: RouterPresentationCompletionError.completionAlreadyPending(presentationID)
        ) {
            try await store.finishPresentation(returning: "second")
        }
        gate.release()
        try await first.value
        #expect(await awaiting.value == .value("first"))
    }

    @Test("Interactive dismissal is distinct from returning a value")
    @MainActor
    func presentationDismissal() async {
        let store = RouterStore<RouteFixture>()
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        await drainMainActor()

        _ = await store.perform(.dismissPresentation)

        #expect(await result.value == .dismissed)
    }

    @Test("Cancelling an awaiting caller dismisses only its presentation")
    @MainActor
    func presentationCancellation() async {
        let store = RouterStore<RouteFixture>()
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        await drainMainActor()

        result.cancel()
        #expect(await result.value == .cancelled)
        await drainMainActor()
        #expect(store.state.root == .stack())
    }

    @Test("Cancellation during presentation policy never commits or leaks a waiter")
    @MainActor
    func presentationCancellationDuringPolicy() async {
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "slow") { _ in
                        try? await Task.sleep(for: .seconds(30))
                        return .allow
                    }
                ]
            )
        )
        var events = store.events.makeAsyncIterator()
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        guard case .started = await events.next() else {
            Issue.record("Expected presentation transition to start")
            return
        }

        result.cancel()

        #expect(await result.value == .cancelled)
        #expect(store.state.root == .stack())
        #expect(store.revision == 0)
    }

    @Test("A destination cannot return the wrong result type")
    @MainActor
    func presentationResultTypeMismatch() async {
        let store = RouterStore<RouteFixture>()
        let result = Task { @MainActor in
            await store.present(.detail, expecting: String.self)
        }
        await drainMainActor()
        guard case .stack(let stack) = store.state.root,
              let presentationID = stack.presentation?.id else {
            Issue.record("Expected active presentation")
            return
        }

        await #expect(
            throws: RouterPresentationCompletionError.resultTypeMismatch(presentationID)
        ) {
            try await store.finishPresentation(returning: 42)
        }
        _ = await store.perform(.dismissPresentation)
        #expect(await result.value == .dismissed)
    }

    @Test("Snapshot restore uses the normal policy and atomic commit pipeline")
    @MainActor
    func snapshotRestoration() async throws {
        let codec = try RouterSnapshotCodec<RouteFixture>(currentVersion: 1)
        let source = RouterStore<RouteFixture>(initialPath: [.detail, .settings])
        let data = try await source.snapshot(using: codec)
        let restored = RouterStore<RouteFixture>()

        let outcome = try await restored.restore(from: data, using: codec)

        guard case .applied(_, _, let after, let revision) = outcome else {
            Issue.record("Expected restored state to commit")
            return
        }
        #expect(after.root == .stack(path: [.detail, .settings]))
        #expect(restored.state == after)
        #expect(revision == 1)
    }

    @Test("Transition context reaches policies and correlated events unchanged")
    @MainActor
    func transitionContextPropagation() async {
        let recorder = EventRecorder()
        let expected = RouterTransitionContext(
            source: .inspector,
            animation: .spring(duration: 0.25, bounce: 0.1)
        )
        let store = RouterStore<RouteFixture>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "context") { transition in
                        recorder.policyContexts.append(transition.context)
                        return .allow
                    }
                ],
                onEvent: { event in recorder.events.append(event) }
            )
        )

        _ = await store.perform(.push(.detail), context: expected)

        guard case .started(let transition) = recorder.events.first else {
            Issue.record("Expected a started event")
            return
        }
        #expect(transition.context == expected)
        #expect(recorder.policyContexts == [expected])
    }

    @Test("A retained scope reports missing authority after its store is released")
    @MainActor
    func releasedStoreScope() async {
        var store: RouterStore<RouteFixture>? = RouterStore()
        let scope = store!.scope()
        store = nil

        let outcome = await scope.perform(.push(.detail))

        guard case .rejected(_, _, _, let reason) = outcome else {
            Issue.record("Expected missing-authority rejection")
            return
        }
        #expect(
            reason == .missingAuthority(
                routeType: String(describing: RouteFixture.self)
            )
        )
    }

    @MainActor
    private func drainMainActor() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}
