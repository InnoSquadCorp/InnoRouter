import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("RouterStore active policy operation budget", .timeLimit(.minutes(1)))
@MainActor
struct RouterPolicyOperationBudgetTests {
    private enum R: Route { case detail(Int) }

    @MainActor
    private final class Recorder {
        var calls = 0
        var terminals: [RouterTransitionID: Int] = [:]

        func record(_ event: RouterEvent<R>) {
            let id: RouterTransitionID
            switch event {
            case .committed(let value, _, _, _, _), .unchanged(let value, _, _, _),
                 .deferred(let value, _, _, _, _), .rejected(let value, _, _, _, _):
                id = value
            case .started, .policyPrepared, .platformAdapted:
                return
            }
            terminals[id, default: 0] += 1
        }
    }

    @Test("Timed-out policy work saturates before invoking further policies")
    func timedOutWorkStaysBounded() async {
        let gates = [PolicyBudgetGate(), PolicyBudgetGate()]
        let sleeper = ManualRuntimeSleeper()
        var registrations = sleeper.registrations.makeAsyncIterator()
        let recorder = Recorder()
        var configuration = RouterStoreConfiguration<R>(
            policies: [RouterPolicy(name: "remote") { _ in
                let index = recorder.calls
                recorder.calls += 1
                if gates.indices.contains(index) { await gates[index].wait() }
                return .allow
            }],
            policyTimeout: .seconds(30),
            maximumActivePolicyOperationCount: 2,
            onEvent: recorder.record
        )
        configuration.runtimeDependencies.sleep = { try await sleeper.sleep(for: $0) }
        let store = RouterStore<R>(configuration: configuration)
        var timedOutIDs: [RouterTransitionID] = []
        for index in gates.indices {
            let request = store.dispatch(.push(.detail(index)))
            await gates[index].waitUntilEntered()
            #expect(await registrations.next() == .seconds(30))
            await sleeper.resumeAll()
            guard case .rejected(let id, _, _, .policyTimedOut(name: "remote")) = await request.value else {
                Issue.record("Expected a timed-out request")
                for gate in gates { gate.release() }
                return
            }
            timedOutIDs.append(id)
            #expect(store.policyOperations.activeCount == index + 1)
            #expect(store.activePolicyRaces.isEmpty)
        }
        for index in 0..<1_000 {
            let outcome = await store.perform(.push(.detail(index + 2)))
            guard case .rejected(_, let state, let revision, .policyCapacityExceeded(limit: 2)) = outcome else {
                Issue.record("Expected typed rejection before the policy is invoked")
                for gate in gates { gate.release() }
                return
            }
            #expect(state == .rootStack)
            #expect(revision == 0)
        }
        #expect(recorder.calls == 2)
        #expect(store.policyOperations.activeCount == 2)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(recorder.terminals.count == 1_002)
        #expect(recorder.terminals.values.allSatisfy { $0 == 1 })

        gates[0].release()
        await gates[0].waitUntilExited()
        #expect(store.policyOperations.activeCount == 1)
        guard case .applied = await store.perform(.push(.detail(1_002))) else {
            Issue.record("Capacity must be reusable after actual exit")
            gates[1].release()
            return
        }
        gates[1].release()
        await gates[1].waitUntilExited()
        #expect(store.policyOperations.activeCount == 0)
        #expect(recorder.calls == 3)
        #expect(store.state == .rootStack(path: [.detail(1_002)]))
        #expect(store.revision == 1)
        #expect(recorder.terminals.count == 1_003)
        for id in timedOutIDs { #expect(recorder.terminals[id] == 1) }
    }

    @Test("Caller cancellation releases the lane but keeps live policy capacity occupied")
    func cancelledWorkStaysBounded() async {
        let gate = PolicyBudgetGate()
        let recorder = Recorder()
        let store = RouterStore<R>(configuration: .init(
            policies: [RouterPolicy(name: "remote") { _ in
                recorder.calls += 1
                if recorder.calls == 1 { await gate.wait() }
                return .allow
            }],
            maximumActivePolicyOperationCount: 1,
            onEvent: recorder.record
        ))
        let request = store.dispatch(.push(.detail(0)))
        await gate.waitUntilEntered()
        request.cancel()
        guard case .rejected(let cancelledID, _, _, .cancelled) = await request.value else {
            Issue.record("Expected caller cancellation")
            gate.release()
            return
        }
        #expect(store.policyOperations.activeCount == 1)
        guard case .rejected(_, _, _, .policyCapacityExceeded(limit: 1)) = await store.perform(.push(.detail(1))) else {
            Issue.record("Expected active-operation back-pressure")
            gate.release()
            return
        }
        #expect(recorder.calls == 1)
        #expect(store.revision == 0)
        gate.release()
        await gate.waitUntilExited()
        #expect(store.policyOperations.activeCount == 0)
        #expect(store.state == .rootStack)
        guard case .applied = await store.perform(.push(.detail(2))) else {
            Issue.record("Expected next request to commit after slot recovery")
            return
        }
        #expect(store.revision == 1)
        #expect(store.state == .rootStack(path: [.detail(2)]))
        #expect(recorder.terminals[cancelledID] == 1)
        #expect(recorder.terminals.values.allSatisfy { $0 == 1 })
    }

    @Test("Configuration preserves timeout defaults and handles zero capacity without policy calls")
    func configurationBoundaries() async {
        let defaults = RouterStoreConfiguration<R>()
        #expect(defaults.maximumActivePolicyOperationCount == 64)
        #expect(defaults.policyTimeout == nil)
        for limit in [-1, 0] {
            let recorder = Recorder()
            let store = RouterStore<R>(configuration: .init(
                policies: [RouterPolicy(name: "must not run") { _ in
                    recorder.calls += 1
                    return .allow
                }],
                maximumActivePolicyOperationCount: limit
            ))
            guard case .rejected(_, _, _, .policyCapacityExceeded(limit: 0)) = await store.perform(.push(.detail(0))) else {
                Issue.record("Expected normalized zero-capacity rejection")
                return
            }
            #expect(recorder.calls == 0)
            #expect(store.policyOperations.activeCount == 0)
            #expect(store.revision == 0)
        }
        let noPolicies = RouterStore<R>(configuration: .init(maximumActivePolicyOperationCount: 0))
        guard case .applied = await noPolicies.perform(.push(.detail(0))) else {
            Issue.record("A zero policy bound must not block policy-free transitions")
            return
        }
        let immediateTimeout = RouterStore<R>(configuration: .init(
            policies: [RouterPolicy(name: "expired") { _ in
                Issue.record("An expired timeout must not invoke policy work")
                return .allow
            }],
            policyTimeout: .zero,
            maximumActivePolicyOperationCount: 0
        ))
        guard case .rejected(_, _, _, .policyTimedOut(name: "expired")) = await immediateTimeout.perform(.push(.detail(0))) else {
            Issue.record("Existing immediate-timeout semantics must be preserved")
            return
        }
        #expect(immediateTimeout.policyOperations.activeCount == 0)
    }

    @Test("Sequential policies reuse the same capacity slot")
    func sequentialPoliciesReuseCapacity() async {
        let recorder = Recorder()
        let store = RouterStore<R>(configuration: .init(
            policies: (0..<3).map { index in
                RouterPolicy(name: "policy-\(index)") { _ in
                    recorder.calls += 1
                    return .allow
                }
            },
            maximumActivePolicyOperationCount: 1
        ))
        guard case .applied = await store.perform(.push(.detail(0))) else {
            Issue.record("Completed policies must release capacity before the next policy")
            return
        }
        #expect(recorder.calls == 3)
        #expect(store.policyOperations.activeCount == 0)
        #expect(store.revision == 1)
    }

    @Test("A live cancelled operation retains its registry without retaining the Store")
    func operationDoesNotRetainStore() async {
        let gate = PolicyBudgetGate()
        var store: RouterStore<R>? = RouterStore(configuration: .init(
            policies: [RouterPolicy(name: "remote") { _ in
                await gate.wait()
                return .allow
            }],
            maximumActivePolicyOperationCount: 1
        ))
        let weakStore = PolicyBudgetWeakReference(store)
        let weakRegistry = PolicyBudgetWeakReference(store?.policyOperations)
        let request = store!.dispatch(.push(.detail(0)))
        await gate.waitUntilEntered()
        request.cancel()
        guard case .rejected(_, _, _, .cancelled) = await request.value else {
            Issue.record("Expected cancellation")
            gate.release()
            return
        }
        store = nil
        #expect(weakStore.value == nil)
        #expect(weakRegistry.value?.activeCount == 1)
        gate.release()
        await gate.waitUntilExited()
        #expect(weakRegistry.value == nil)
    }
}

@MainActor
private final class PolicyBudgetGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var exited = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        exited = true
        let waiters = exitedWaiters
        exitedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }

    func waitUntilExited() async {
        if !exited { await withCheckedContinuation { exitedWaiters.append($0) } }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PolicyBudgetWeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
