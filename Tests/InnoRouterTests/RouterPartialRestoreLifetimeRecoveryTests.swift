import Testing
import InnoRouterCore
import InnoRouterSwiftUI

@Suite("Partial restoration lifetime recovery")
@MainActor
struct RouterPartialRestoreLifetimeRecoveryTests {
    private enum R: String, Route, Codable { case home, restored, detail }

    @Test("Public partial restore replaces ownership for equal and changed state", arguments: [false, true])
    func partialRestoreExpiresCapturedScope(changed: Bool) async throws {
        let initial = RouterState<R>.rootStack(path: [.home])
        let target = changed ? RouterState<R>.rootStack(path: [.restored]) : initial
        let store = RouterStore<R>(initialState: initial)
        let old = store.scope()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let outcome = try await store.restorePartially(
            from: codec.encode(target), using: codec,
            validator: .init { _, _ in .keep }
        )
        if changed {
            guard case .applied = outcome.transition else {
                Issue.record("Changed restoration must apply")
                return
            }
        } else {
            guard case .unchanged = outcome.transition else {
                Issue.record("Equal restoration keeps the state revision unchanged")
                return
            }
        }
        #expect(store.state == target)
        #expect(store.revision == (changed ? 1 : 0))
        #expect(old.node == nil)
        let fresh = store.scope()
        #expect(old !== fresh)
        guard case .rejected = await old.perform(.push(.detail)) else {
            Issue.record("Pre-restore scope regained execution authority")
            return
        }
        #expect(store.state == target)
        guard case .applied = await fresh.perform(.push(.detail)) else {
            Issue.record("Newly acquired owner must remain usable")
            return
        }
        #expect(store.revision == (changed ? 2 : 1))
    }

    @Test("A rejected partial restore retains the prior owner and value")
    func rejectedRestoreRetainsOwnership() async throws {
        let initial = RouterState<R>.rootStack(path: [.home])
        let store = RouterStore<R>(initialState: initial, configuration: .init(
            policies: [.init(name: "reject-restore") { _ in .reject("control") }]
        ))
        let old = store.scope()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let outcome = try await store.restorePartially(
            from: codec.encode(initial), using: codec,
            validator: .init { _, _ in .keep }
        )
        guard case .rejected = outcome.transition else {
            Issue.record("Ownership replacement still requires policy admission")
            return
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(old.node == initial.root)
        #expect(old === store.scope())
    }
}
