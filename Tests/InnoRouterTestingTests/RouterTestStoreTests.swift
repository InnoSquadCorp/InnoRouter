import Foundation
import Testing

import InnoRouter
@testable import InnoRouterTesting

private enum CanonicalTestRoute: String, Route, Codable {
    case home
    case privateArea
}

@MainActor
private final class CancellationAwareGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancellationCount = 0

    func wait() async {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        cancellationCount += 1
        release()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("RouterTestStore")
struct RouterTestStoreTests {
    @Test("Virtual time deterministically times out partial restoration validation")
    @MainActor
    func virtualPartialRestorationTimeout() async throws {
        let runtime = RouterTestRuntime()
        let never = AsyncStream<Void> { _ in }
        let codec = try RouterSnapshotCodec<CanonicalTestRoute>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.home]))
        let store = RouterTestStore<CanonicalTestRoute>(runtime: runtime)
        let validator = RouterPartialRestorationValidator<CanonicalTestRoute> { _, _ in
            for await _ in never { break }
            return .keep
        }
        let task = Task { @MainActor in
            try await store.restorePartially(
                from: data,
                using: codec,
                validator: validator,
                validationTimeout: .seconds(5)
            )
        }

        await runtime.clock.waitUntilScheduled()
        runtime.clock.advance(by: .seconds(5))

        do {
            _ = try await task.value
            Issue.record("Expected partial restoration validation timeout")
        } catch let error as RouterPartialRestorationError {
            #expect(error == .validationTimedOut)
        }
        #expect(store.state == .rootStack)
        #expect(store.pendingWork.isEmpty)
        await store.finish()
    }

    @Test("Virtual time drives a production policy timeout")
    @MainActor
    func virtualPolicyTimeout() async {
        let runtime = RouterTestRuntime(transitionIDSeed: 7)
        let never = AsyncStream<Void> { _ in }
        let store = RouterTestStore<CanonicalTestRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "slow") { _ in
                        for await _ in never { break }
                        return .allow
                    }
                ],
                policyTimeout: .seconds(30)
            ),
            runtime: runtime
        )

        let request = store.start(.push(.privateArea))
        #expect(await request.waitUntilStarted())
        await runtime.clock.waitUntilScheduled()
        #expect(runtime.clock.pendingSleepCount == 1)

        runtime.clock.advance(by: .seconds(30))
        let outcome = await request.result

        #expect(request.id.rawValue.uuidString == "60000000-0000-0000-0000-000000000007")
        guard case .rejected(_, _, _, .policyTimedOut(name: "slow")) = outcome else {
            Issue.record("Expected virtual policy timeout")
            return
        }
        store.receiveStarted()
        store.receiveRejected { $0 == .policyTimedOut(name: "slow") }
        #expect(store.pendingWork.isEmpty)
        await store.finish()
    }

    @Test("Finishing one store never cancels another store's shared-clock timer")
    @MainActor
    func sharedRuntimeTimerOwnership() async {
        let runtime = RouterTestRuntime()
        let (firstGate, firstContinuation) = AsyncStream<Void>.makeStream()
        let (secondGate, secondContinuation) = AsyncStream<Void>.makeStream()
        let configuration = RouterStoreConfiguration<CanonicalTestRoute>(
            policies: [
                RouterPolicy(name: "slow") { transition in
                    let gate = transition.action == .push(.home) ? firstGate : secondGate
                    for await _ in gate { break }
                    return .allow
                }
            ],
            policyTimeout: .seconds(30)
        )
        var firstStore: RouterTestStore<CanonicalTestRoute>? = RouterTestStore(
            configuration: configuration,
            exhaustivity: .off,
            runtime: runtime
        )
        let secondStore = RouterTestStore<CanonicalTestRoute>(
            configuration: configuration,
            exhaustivity: .off,
            runtime: runtime
        )
        let firstRequest = firstStore?.start(.push(.home))
        let secondRequest = secondStore.start(.push(.privateArea))
        await runtime.clock.waitUntilScheduled(2)

        firstStore = nil

        #expect(runtime.clock.pendingSleepCount == 1)
        guard let firstRequest,
              case .rejected(_, _, _, .cancelled) = await firstRequest.result else {
            Issue.record("Expected the deallocated store request to cancel")
            return
        }

        runtime.clock.advance(by: .seconds(30))
        let secondOutcome = await secondRequest.result
        firstContinuation.finish()
        secondContinuation.finish()
        guard case .rejected(_, _, _, .policyTimedOut(name: "slow")) = secondOutcome else {
            Issue.record("Expected the surviving store timer to remain scheduled, got \(secondOutcome)")
            return
        }
        secondStore.skipReceivedEvents()
        #expect(secondStore.pendingWork.isEmpty)
        await secondStore.finish()
    }

    @Test("A store timer barrier ignores another owner on the shared clock")
    @MainActor
    func ownTimerBarrierDoesNotUseOtherStore() async {
        let runtime = RouterTestRuntime()
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let configuration = RouterStoreConfiguration<CanonicalTestRoute>(
            policies: [RouterPolicy(name: "slow") { _ in
                for await _ in gate { break }
                return .allow
            }],
            policyTimeout: .seconds(30)
        )
        let first = RouterTestStore<CanonicalTestRoute>(
            configuration: configuration,
            exhaustivity: .off,
            runtime: runtime
        )
        let second = RouterTestStore<CanonicalTestRoute>(
            exhaustivity: .off,
            runtime: runtime
        )
        let request = first.start(.push(.home))
        #expect(await first.waitUntilTimeIsScheduled())

        let barrier = Task { @MainActor in await second.waitUntilTimeIsScheduled() }
        try? await Task.sleep(for: .milliseconds(30))
        barrier.cancel()

        #expect(await barrier.value == false)
        request.cancel()
        _ = await request.result
        continuation.finish()
        first.skipReceivedEvents()
        await first.finish()
        await second.finish()
    }

    @Test("Finish reports then clears owned deferrals")
    @MainActor
    func finishClearsOwnedDeferrals() async {
        let store = RouterTestStore<CanonicalTestRoute>(
            configuration: .init(policies: [
                RouterPolicy(name: "approval") { _ in
                    .deferRequest(RouterDeferralID())
                },
            ]),
            exhaustivity: .off
        )
        guard case .deferred = await store.send(.push(.privateArea)) else {
            Issue.record("Expected a pending deferral")
            return
        }
        #expect(store.pendingWork.deferrals == 1)

        await withKnownIssue("finish must diagnose pending work before cleanup") {
            await store.finish()
        }

        #expect(store.pendingWork.isEmpty)
    }

    @Test("A queued request can be cancelled before it starts")
    @MainActor
    func queuedCancellationBarrier() async {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let store = RouterTestStore<CanonicalTestRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "gate") { _ in
                        for await _ in gate { break }
                        return .allow
                    }
                ]
            )
        )
        let active = store.start(.push(.home))
        #expect(await active.waitUntilStarted())
        let queued = store.start(.push(.privateArea))
        queued.cancel()

        let queuedStarted = await queued.waitUntilStarted()
        let queuedOutcome = await queued.result
        #expect(queuedStarted == false)
        guard case .rejected(_, _, _, .cancelled) = queuedOutcome else {
            Issue.record("Expected queued cancellation")
            gateContinuation.finish()
            return
        }

        gateContinuation.yield()
        gateContinuation.finish()
        _ = await active.result
        store.skipReceivedEvents()
        #expect(store.pendingWork.isEmpty)
        await store.finish()
    }

    @Test("A queued request keeps cancellation ownership after it becomes active")
    @MainActor
    func activeQueuedRequestCancellation() async {
        let (firstGate, firstContinuation) = AsyncStream<Void>.makeStream()
        let cancellationGate = CancellationAwareGate()
        let store = RouterTestStore<CanonicalTestRoute>(
            configuration: .init(policies: [
                RouterPolicy(name: "gate") { transition in
                    if transition.action == .push(.home) {
                        for await _ in firstGate { break }
                    } else {
                        await cancellationGate.wait()
                    }
                    return .allow
                },
            ]),
            exhaustivity: .off
        )
        let active = store.start(.push(.home))
        #expect(await active.waitUntilStarted())
        let queued = store.start(.push(.privateArea))
        #expect(await queued.waitUntilQueued())

        firstContinuation.finish()
        _ = await active.result
        #expect(await queued.waitUntilStarted())
        queued.cancel()

        guard case .rejected(_, _, _, .cancelled) = await queued.result else {
            Issue.record("Expected the promoted queued request to cancel")
            cancellationGate.release()
            return
        }
        #expect(cancellationGate.cancellationCount == 1)
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 1)
        #expect(store.pendingWork.isEmpty)

        guard case .applied = await store.send(.push(.home)) else {
            Issue.record("Expected the next FIFO request to run")
            return
        }
        store.skipReceivedEvents()
        await store.finish()
    }

    @Test("Virtual time expires a deferred request and clears pending work")
    @MainActor
    func virtualDeferralExpiry() async {
        let runtime = RouterTestRuntime(
            clock: RouterTestClock(now: Date(timeIntervalSince1970: 1_000))
        )
        let deferralID = RouterDeferralID(
            rawValue: UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        )
        let store = RouterTestStore<CanonicalTestRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { _ in
                        .deferRequest(deferralID)
                    }
                ],
                deferrals: .init(timeToLive: .seconds(60))
            ),
            runtime: runtime
        )

        let request = store.start(.push(.privateArea))
        #expect(await request.waitUntilStarted())
        guard case .deferred(_, _, _, let metadata) = await request.result else {
            Issue.record("Expected deferred outcome")
            return
        }
        #expect(metadata.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(metadata.expiresAt == Date(timeIntervalSince1970: 1_060))
        await runtime.clock.waitUntilScheduled()
        #expect(
            store.pendingWork == RouterTestPendingWork(
                requests: 0,
                deferrals: 1,
                timers: 1
            )
        )

        runtime.clock.advance(by: .seconds(60))
        await store.waitForEvent { event in
            guard case .rejected(_, _, _, .deferralExpired(let id), _) = event else {
                return false
            }
            return id == deferralID
        }

        store.skipReceivedEvents()
        #expect(store.pendingWork.isEmpty)
        await store.finish()
    }

    @Test("Correlated production events are asserted in order")
    @MainActor
    func lifecycle() async {
        let store = RouterTestStore<CanonicalTestRoute>()

        let outcome = await store.send(.push(.home))

        store.receiveStarted { transition in
            transition.id == outcome.id && transition.action == .push(.home)
        }
        store.receiveCommitted { state, revision in
            state.root == .stack(path: [.home]) && revision == 1
        }
        #expect(store.state.root == .stack(path: [.home]))
        await store.finish()
    }

    @Test("Cancelling an event barrier removes its continuation and pending-work entry")
    @MainActor
    func cancelledEventBarrierIsDrained() async {
        let store = RouterTestStore<CanonicalTestRoute>()
        let waiter = Task { @MainActor in
            await store.waitForEvent { event in
                if case .started = event { return true }
                return false
            }
        }
        await store.waitUntilPendingWaiterCount(1)

        waiter.cancel()

        #expect(await waiter.value == nil)
        #expect(store.pendingWork.isEmpty)
        await store.finish()
    }

    @Test("Production policy rejection is injected without a second fake reducer")
    @MainActor
    func policyFailure() async {
        let store = RouterTestStore<CanonicalTestRoute>(
            configuration: .init(
                policies: [
                    RouterPolicy(name: "authorization") { transition in
                        transition.action == .push(.privateArea)
                            ? .reject("denied")
                            : .allow
                    }
                ]
            )
        )

        _ = await store.send(.push(.privateArea))

        store.receiveStarted()
        store.receive { event in
            guard case .policyPrepared(_, "authorization", .reject("denied")) = event else {
                return false
            }
            return true
        }
        store.receiveRejected { reason in
            reason == .policy(name: "authorization", message: "denied")
        }
        #expect(store.state.root == .stack())
        await store.finish()
    }

    @Test("Plan sends preserve transition context and unchanged assertions")
    @MainActor
    func planAndContext() async {
        let store = RouterTestStore<CanonicalTestRoute>()
        let plan = RouterPlan<CanonicalTestRoute>(
            state: .rootStack(path: [.home])
        )

        _ = await store.send(
            plan,
            context: .init(source: .appIntent, animation: RouterAnimation.none)
        )
        store.receiveStarted { transition in
            transition.context.source == .appIntent
                && transition.context.animation == RouterAnimation.none
        }
        store.receiveCommitted()

        _ = await store.send(plan)
        store.receiveUnchanged { state, revision in
            state == plan.state && revision == 1
        }
        store.assertState(plan.state)
        await store.finish()
    }

    @Test("Snapshot helpers use production restoration provenance")
    @MainActor
    func snapshotHelpers() async throws {
        let codec = try RouterSnapshotCodec<CanonicalTestRoute>(currentVersion: 1)
        let source = RouterTestStore<CanonicalTestRoute>(initialPath: [.home])
        let data = try await source.snapshot(using: codec)
        await source.finish()

        let target = RouterTestStore<CanonicalTestRoute>()
        let restoration = try await target.restore(from: data, using: codec)

        guard case .restored(let state) = restoration.decoding else {
            Issue.record("Expected restored provenance")
            return
        }
        #expect(state.root == .stack(path: [.home]))
        target.receiveStarted { $0.context.source == .restoration }
        target.receiveCommitted()
        await target.finish()
    }
}
