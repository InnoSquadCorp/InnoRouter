import Foundation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum TwentySecondReviewRoute: String, Route, Codable {
    case saved
    case current
}

private struct TwentySecondReviewStorageState: Sendable {
    var data: Data?
    var loadCount = 0
}

private final class TwentySecondReviewBlockingStorage: RouterSnapshotStorage {
    private enum StorageError: Error {
        case loadTimedOut
    }

    let loads: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let firstLoadBarrier = DispatchSemaphore(value: 0)
    private let blocksFirstLoad: Bool
    private let state: Mutex<TwentySecondReviewStorageState>

    init(data: Data, blocksFirstLoad: Bool) {
        self.blocksFirstLoad = blocksFirstLoad
        state = Mutex(.init(data: data))
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        firstLoadBarrier.signal()
        loadContinuation.finish()
    }

    var snapshot: TwentySecondReviewStorageState { state.withLock { $0 } }

    func releaseFirstLoad() {
        firstLoadBarrier.signal()
    }

    func load() throws -> Data? {
        let count = state.withLock { state in
            state.loadCount += 1
            return state.loadCount
        }
        loadContinuation.yield()
        if blocksFirstLoad, count == 1,
           firstLoadBarrier.wait(timeout: .now() + 5) != .success {
            throw StorageError.loadTimedOut
        }
        return state.withLock { $0.data }
    }

    func save(_ data: Data) throws {
        state.withLock { $0.data = data }
    }

    func remove() throws {
        state.withLock { $0.data = nil }
    }
}

@Suite("Twenty-second review restoration lifetime", .timeLimit(.minutes(1)))
@MainActor
struct RouterTwentySecondReviewRegressionTests {
    @Test("Navigation accepted before the restoration worker loads wins deterministically")
    func preLoadWorkerBarrierProtectsNewNavigation() async throws {
        let codec = try RouterSnapshotCodec<TwentySecondReviewRoute>(currentVersion: 1)
        let storage = TwentySecondReviewBlockingStorage(
            data: try codec.encode(.rootStack(path: [.saved])),
            blocksFirstLoad: true
        )
        let workerGate = ManualRuntimeSleeper()
        var configuration = RouterStoreConfiguration<TwentySecondReviewRoute>()
        configuration.runtimeDependencies.beforeRestorationWorker = {
            try await workerGate.sleep(for: .seconds(60))
        }
        let store = RouterStore<TwentySecondReviewRoute>(configuration: configuration)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            Task { await workerGate.resumeAll() }
            storage.releaseFirstLoad()
            driver.stop()
        }

        _ = try await firstElement(
            from: workerGate.registrations,
            what: "restoration worker reservation"
        )
        #expect(storage.snapshot.loadCount == 0)
        #expect(store.eventObservationCount == 1)
        guard case .applied = await store.perform(.push(.current)) else {
            Issue.record("navigation was not accepted before the restore worker started")
            return
        }
        #expect(store.revision == 1)

        await workerGate.resumeAll()
        _ = try await firstElement(from: storage.loads, what: "snapshot load")
        storage.releaseFirstLoad()
        _ = try await activation.value

        #expect(storage.snapshot.loadCount == 1)
        #expect(store.state.root == .stack(path: [.current]))
        #expect(store.revision == 1)
    }

    @Test("An explicit stop remains observation-only across later detach cycles")
    func explicitStopSurvivesDetachCycles() async throws {
        let codec = try RouterSnapshotCodec<TwentySecondReviewRoute>(currentVersion: 1)
        let storage = TwentySecondReviewBlockingStorage(
            data: try codec.encode(.rootStack(path: [.saved])),
            blocksFirstLoad: true
        )
        let store = RouterStore<TwentySecondReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .seconds(3_600)
        )
        let firstOwner = UUID()
        let first = Task { @MainActor in try await driver.attach(firstOwner) }
        defer {
            first.cancel()
            storage.releaseFirstLoad()
            driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "the first restore load")

        driver.stop()
        storage.releaseFirstLoad()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        _ = await store.perform(.push(.current))
        let expectedState = store.state
        let expectedRevision = store.revision

        for _ in 0 ..< 2 {
            let owner = UUID()
            let activation = try await driver.attach(owner)
            if case .observationResumed = activation {} else {
                Issue.record("explicit stop was lost: \(activation)")
            }
            #expect(store.state == expectedState)
            #expect(store.revision == expectedRevision)
            #expect(storage.snapshot.loadCount == 1)
            #expect(store.eventObservationCount == 1)

            driver.detach(owner)
            #expect(store.eventObservationCount == 0)
        }

        #expect(store.state.root == .stack(path: [.current]))
        #expect(store.revision == 1)
    }

    @Test("Stopping before the first activation does not disable restoration")
    func stopBeforeFirstActivationKeepsInitialRestore() async throws {
        let codec = try RouterSnapshotCodec<TwentySecondReviewRoute>(currentVersion: 1)
        let storage = TwentySecondReviewBlockingStorage(
            data: try codec.encode(.rootStack(path: [.saved])),
            blocksFirstLoad: false
        )
        let store = RouterStore<TwentySecondReviewRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        defer { driver.stop() }

        driver.stop()
        let activation = try await driver.activate()
        guard case .restored = activation else {
            Issue.record("stop before the first attempt disabled restoration: \(activation)")
            return
        }
        #expect(storage.snapshot.loadCount == 1)
        #expect(store.state.root == .stack(path: [.saved]))
        #expect(store.revision == 1)
    }
}
