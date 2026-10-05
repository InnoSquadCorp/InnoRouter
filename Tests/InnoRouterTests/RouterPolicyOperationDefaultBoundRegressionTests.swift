import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

/// Uses only the pre-S03 public API so the same behavioral regression can be
/// copied to the baseline: previously the 65th policy ran and committed while
/// all 64 cancelled operations were still alive. The development default is
/// deliberately asserted here; its release calibration remains a separate gate.
@Suite("Default policy operation bound regression", .timeLimit(.minutes(1)))
@MainActor
struct RouterPolicyOperationDefaultBoundRegressionTests {
    private enum R: Route { case detail }

    @Test("Repeated logical cancellation cannot admit unlimited actual policy work")
    func repeatedCancellationPreservesDefaultBound() async throws {
        let gate = DefaultPolicyBudgetGate()
        let store = try RouterStore<R>(configuration: .init(policies: [
            RouterPolicy(name: "remote") { _ in
                await gate.enter()
                return .allow
            },
        ]))
        defer { gate.releaseAll() }
        for expectedCount in 1...64 {
            let request = store.dispatch(.push(.detail))
            await gate.waitForEntry(expectedCount)
            request.cancel()
            guard case .rejected(_, _, _, .cancelled) = await request.value else {
                Issue.record("The original request should finish as cancelled")
                return
            }
        }
        let overflow = await store.perform(.push(.detail))
        guard case .rejected = overflow else {
            Issue.record("The 65th policy ran despite 64 noncooperative operations still alive")
            return
        }
        #expect(gate.calls == 64)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        gate.releaseAll()
        await gate.waitForExit(64)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }
}

@MainActor
private final class DefaultPolicyBudgetGate {
    private(set) var calls = 0
    private var exits = 0
    private var operations: [CheckedContinuation<Void, Never>] = []
    private var entries: [(Int, CheckedContinuation<Void, Never>)] = []
    private var exitWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter() async {
        calls += 1
        let ready = entries.filter { $0.0 <= calls }
        entries.removeAll { $0.0 <= calls }
        for (_, waiter) in ready { waiter.resume() }
        // If a broken implementation invokes the saturated policy, let it
        // finish so this regression fails on the unintended commit, not a hang.
        guard calls <= 64 else { return }
        await withCheckedContinuation { operations.append($0) }
        exits += 1
        let finished = exitWaiters.filter { $0.0 <= exits }
        exitWaiters.removeAll { $0.0 <= exits }
        for (_, waiter) in finished { waiter.resume() }
    }

    func waitForEntry(_ count: Int) async {
        if calls < count { await withCheckedContinuation { entries.append((count, $0)) } }
    }

    func waitForExit(_ count: Int) async {
        if exits < count { await withCheckedContinuation { exitWaiters.append((count, $0)) } }
    }

    func releaseAll() {
        let pending = operations
        operations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
