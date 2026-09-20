import Foundation
import Synchronization
import Testing

import InnoRouter

private enum PartialDriverRoute: String, Route, Codable {
    case home
    case retired
    case detail
}

private final class PartialDriverStorage: RouterSnapshotStorage, Sendable {
    private struct State {
        var data: Data?
        var saveCount = 0
    }

    private let state: Mutex<State>
    let saves: AsyncStream<Data>
    private let saveContinuation: AsyncStream<Data>.Continuation

    init(_ data: Data?) {
        state = Mutex(State(data: data))
        (saves, saveContinuation) = AsyncStream.makeStream()
    }

    var storedData: Data? { state.withLock { $0.data } }
    var saveCount: Int { state.withLock { $0.saveCount } }

    func load() throws -> Data? { state.withLock { $0.data } }

    func save(_ data: Data) throws {
        state.withLock {
            $0.data = data
            $0.saveCount += 1
        }
        saveContinuation.yield(data)
    }

    func remove() throws {
        state.withLock { $0.data = nil }
    }
}

@MainActor
private final class PartialDriverValidationGate {
    let entries: AsyncStream<Void>
    let completions: AsyncStream<Void>
    private let entryContinuation: AsyncStream<Void>.Continuation
    private let completionContinuation: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?

    init() {
        (entries, entryContinuation) = AsyncStream.makeStream()
        (completions, completionContinuation) = AsyncStream.makeStream()
    }

    func suspendIgnoringCancellation() async {
        entryContinuation.yield(())
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        completionContinuation.yield(())
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Partial automatic restoration")
@MainActor
struct RouterRestorationDriverPartialTests {
    private typealias R = PartialDriverRoute

    @Test("An unchanged validated candidate is persisted and reopens without retired routes")
    func unchangedCandidateIsNormalizedOnDisk() async throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let storage = PartialDriverStorage(try codec.encode(.rootStack(path: [.home, .retired])))
        let store = RouterStore(initialState: RouterState<R>.rootStack(path: [.home]))
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            validator: .init { route, _ in
                route == .retired ? .remove(reason: "retired") : .keep
            },
            saveDebounce: .zero
        )
        defer { driver.stop() }

        guard case .restored(let activation) = try await driver.activate(),
              case .unchanged = activation.transition else {
            Issue.record("Expected the validated candidate to match current state")
            return
        }
        let saved = try await firstElement(from: storage.saves, what: "normalized partial snapshot")
        #expect(try codec.decode(saved) == .rootStack(path: [.home]))
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 0)
        #expect(driver.lastPartialRestoration?.report.entries.contains {
            $0.change == .removed && $0.reason == "retired"
        } == true)
        guard case .unchanged = driver.lastPartialRestoration?.transition else {
            Issue.record("Expected the report and transition from the same partial attempt")
            return
        }

        driver.stop()
        let reopened = RouterStore<R>()
        let reopenedDriver = RouterRestorationDriver(
            store: reopened,
            codec: codec,
            storage: storage
        )
        defer { reopenedDriver.stop() }
        guard case .restored(let result) = try await reopenedDriver.activate(),
              case .applied = result.transition else {
            Issue.record("Expected a new driver to apply the normalized file")
            return
        }
        #expect(reopened.state == .rootStack(path: [.home]))
    }

    @Test("An applied partial candidate saves once through normal observation")
    func appliedCandidateUsesAutomaticSave() async throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let storage = PartialDriverStorage(
            try codec.encode(.rootStack(path: [.home, .retired, .detail]))
        )
        let store = RouterStore<R>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            validator: .init { route, _ in
                route == .retired ? .remove(reason: "retired") : .keep
            },
            saveDebounce: .zero
        )
        defer { driver.stop() }

        guard case .restored(let activation) = try await driver.activate(),
              case .applied = activation.transition else {
            Issue.record("Expected one partial restoration commit")
            return
        }
        let saved = try await firstElement(from: storage.saves, what: "applied partial snapshot")
        #expect(try codec.decode(saved) == .rootStack(path: [.home]))
        #expect(store.state == .rootStack(path: [.home]))
        #expect(store.revision == 1)
    }

    @Test("Stopping during a noncooperative validator prevents a late commit and report")
    func stopDuringValidation() async throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let storage = PartialDriverStorage(try codec.encode(.rootStack(path: [.home])))
        let store = RouterStore<R>()
        let gate = PartialDriverValidationGate()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            validator: .init { _, _ in
                await gate.suspendIgnoringCancellation()
                return .keep
            }
        )
        let activation = Task { try await driver.activate() }
        _ = try await firstElement(from: gate.entries, what: "partial validator entry")

        driver.stop()
        await #expect(throws: CancellationError.self) { try await activation.value }
        gate.release()
        _ = try await firstElement(from: gate.completions, what: "retired validator completion")

        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(driver.lastActivation == nil)
        #expect(driver.lastPartialRestoration == nil)
        #expect(driver.status == .inactive)
    }

    @Test("No snapshot clears partial report state")
    func noSnapshot() async throws {
        let driver = RouterRestorationDriver(
            store: RouterStore<R>(),
            codec: try RouterSnapshotCodec(currentVersion: 1),
            storage: PartialDriverStorage(nil),
            validator: .init { _, _ in .keep }
        )
        defer { driver.stop() }
        #expect(try await driver.activate() == .noSnapshot)
        #expect(driver.lastPartialRestoration == nil)
    }

    @Test("A deferred partial candidate is saved only after terminal approval")
    func deferredCandidateWaitsForApproval() async throws {
        let deferral = RouterDeferralID()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let storage = PartialDriverStorage(try codec.encode(.rootStack(path: [.home])))
        let store = RouterStore<R>(configuration: .init(policies: [
            RouterPolicy(name: "approval") { transition in
                transition.context.source == .restoration ? .deferRequest(deferral) : .allow
            },
        ]))
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            validator: .init { _, _ in .keep },
            saveDebounce: .zero
        )
        defer { driver.stop() }

        guard case .restored(let activation) = try await driver.activate(),
              case .deferred = activation.transition,
              case .deferred = driver.lastPartialRestoration?.transition else {
            Issue.record("Expected a reported but uncommitted partial candidate")
            return
        }
        #expect(storage.saveCount == 0)
        #expect(store.revision == 0)
        #expect(store.state == .rootStack)

        guard case .applied = await store.resolveDeferred(deferral, with: .allow) else {
            Issue.record("Expected terminal approval to apply the partial candidate")
            return
        }
        let saved = try await firstElement(from: storage.saves, what: "approved partial snapshot")
        #expect(try codec.decode(saved) == .rootStack(path: [.home]))
        #expect(store.revision == 1)
        #expect(storage.saveCount == 1)
    }
}
