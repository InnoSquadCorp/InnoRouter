import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Store restoration actual operation budget", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterRestorationOperationBudgetTests {
    private typealias R = RestorationBudgetRoute

    @Test("Public partial restore uses a Store-wide bound across new validators and 1,000 retries")
    func publicRestorationSharesBoundAcrossValidators() async throws {
        let gate = RestorationBudgetGate()
        let timer = RestorationBudgetGate()
        var configuration = RouterStoreConfiguration<R>(maximumActiveRestorationOperationCount: 1)
        configuration.runtimeDependencies.sleep = { _ in await timer.suspend() }
        let store = RouterStore<R>(configuration: configuration)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.step(1)]))
        let task = Task { @MainActor in
            try await store.restorePartially(
                from: data, using: codec,
                validator: .init { _, _ in await gate.suspend(); return .keep },
                validationTimeout: .seconds(30)
            )
        }
        await gate.entered.wait()
        await timer.entered.wait()
        timer.released.open()
        await #expect(throws: RouterPartialRestorationError.validationTimedOut) { try await task.value }
        var extraCalls = 0
        var rejections = 0
        for _ in 0..<1_000 {
            do {
                _ = try await store.restorePartially(
                    from: data, using: codec,
                    validator: .init { _, _ in extraCalls += 1; return .keep }
                )
            } catch let error as RouterPartialRestorationError {
                #expect(error == .operation(.capacityExceeded(maximumCount: 1, activeCount: 1)))
                rejections += 1
            }
        }
        #expect(rejections == 1_000)
        #expect(extraCalls == 0)
        #expect(store.restorationOperations.activeCount == 1)
        #expect(store.policyOperations.activeCount == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        gate.released.open()
        await gate.exited.wait()
        #expect(store.restorationOperations.activeCount == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        let recovery = try await store.restorePartially(
            from: data, using: codec, validator: .init { _, _ in .keep }
        )
        guard case .applied = recovery.transition else {
            Issue.record("Actual validator exit must make capacity reusable")
            return
        }
        #expect(store.state == .rootStack(path: [.step(1)]))
        #expect(store.revision == 1)
        #expect(store.restorationOperations.activeCount == 0)
    }

    @Test("Default admission bounds actual work at eight; nil explicitly opts out", arguments: [true, false])
    func defaultAndUnboundedConfiguration(useDefault: Bool) async throws {
        #expect(RouterStoreConfiguration<R>().maximumActiveRestorationOperationCount == 8)
        let configuration = useDefault ? RouterStoreConfiguration<R>() : .init(maximumActiveRestorationOperationCount: nil)
        let store = RouterStore<R>(configuration: configuration)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.step(0)]))
        let count = useDefault ? 8 : 10
        let gates = (0..<count).map { _ in RestorationBudgetGate() }
        for gate in gates {
            let task = Task { @MainActor in
                try await store.restorePartially(
                    from: data, using: codec,
                    validator: .init { _, _ in await gate.suspend(); return .keep }
                )
            }
            await gate.entered.wait()
            task.cancel()
            await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
        }
        #expect(store.restorationOperations.activeCount == count)
        if useDefault {
            await #expect(throws: RouterPartialRestorationError.operation(
                .capacityExceeded(maximumCount: 8, activeCount: 8)
            )) {
                try await store.restorePartially(from: data, using: codec, validator: .init { _, _ in .keep })
            }
        }
        #expect(store.revision == 0)
        for gate in gates {
            gate.released.open()
            await gate.exited.wait()
        }
        #expect(store.restorationOperations.activeCount == 0)
    }

    @Test("Zero and negative capacity reject before callbacks without blocking policy-free navigation", arguments: [0, -1])
    func zeroAndNegativeCapacity(limit: Int) async throws {
        let store = RouterStore<R>(configuration: .init(maximumActiveRestorationOperationCount: limit))
        var calls = 0
        await #expect(throws: RouterPartialRestorationError.operation(
            .capacityExceeded(maximumCount: 0, activeCount: 0)
        )) {
            try await store.restorePartially(
                decoded: .rootStack(path: [.step(0)]),
                validator: .init { _, _ in calls += 1; return .keep },
                tabTopology: nil, validationTimeout: nil, expectedRevision: 0
            )
        }
        #expect(calls == 0)
        #expect(store.restorationOperations.activeCount == 0)
        #expect(store.revision == 0)
        guard case .applied = await store.perform(.push(.step(1))) else {
            Issue.record("The restoration bound must not block normal navigation")
            return
        }
        #expect(store.revision == 1)
    }

    @Test("History validation shares the Store bound, then recovers after actual exit")
    func historySharesStoreCapacity() async throws {
        let store = RouterStore<R>(initialPath: [.step(0)], configuration: .init(maximumActiveRestorationOperationCount: 1))
        var historyCalls = 0
        let history = RouterHistory(store: store, validator: .init { _, _ in historyCalls += 1; return .keep })
        _ = await store.perform(.push(.step(1)))
        #expect(await history.waitUntilRecordedRevision(1))
        let gate = RestorationBudgetGate()
        let task = Task { @MainActor in
            try await store.restorePartially(
                decoded: .rootStack(path: [.step(2)]),
                validator: .init { _, _ in await gate.suspend(); return .keep },
                tabTopology: nil, validationTimeout: nil, expectedRevision: 1
            )
        }
        await gate.entered.wait()
        task.cancel()
        await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
        let blocked = await history.goBack()
        guard case .unavailable(_, .validationFailed(.operation(let failure))) = blocked else {
            Issue.record("History must share the Store's saturated restoration budget")
            gate.released.open()
            await gate.exited.wait()
            return
        }
        #expect(failure == .capacityExceeded(maximumCount: 1, activeCount: 1))
        #expect(historyCalls == 0)
        #expect(store.revision == 1)
        gate.released.open()
        await gate.exited.wait()
        guard case .completed = await history.goBack() else {
            Issue.record("History must recover once actual work exits")
            return
        }
        #expect(historyCalls == 1)
        #expect(store.state == .rootStack(path: [.step(0)]))
        #expect(store.revision == 2)
        #expect(store.restorationOperations.activeCount == 0)
        history.stop()
    }

    @Test("A cancelled validator retains its registry without retaining its Store")
    func operationDoesNotRetainStore() async throws {
        var store: RouterStore<R>? = RouterStore(configuration: .init(maximumActiveRestorationOperationCount: 1))
        let weakStore = RestorationBudgetWeakReference(store)
        let weakRegistry = RestorationBudgetWeakReference(store?.restorationOperations)
        let gate = RestorationBudgetGate()
        let task = Task { @MainActor [store] in
            try await store!.restorePartially(
                decoded: .rootStack(path: [.step(0)]),
                validator: .init { _, _ in await gate.suspend(); return .keep },
                tabTopology: nil, validationTimeout: nil, expectedRevision: 0
            )
        }
        await gate.entered.wait()
        task.cancel()
        await #expect(throws: RouterPartialRestorationError.cancelled) { try await task.value }
        store = nil
        #expect(weakStore.value == nil)
        #expect(weakRegistry.value?.activeCount == 1)
        gate.released.open()
        await gate.exited.wait()
        #expect(weakRegistry.value == nil)
    }
}
