import Foundation
import Synchronization
import Testing

import InnoRouter

private enum TwentyThirdStorageError: Error { case encode, remove, save, timeout }

private enum TwentyThirdStoredRoute: String, Route, Codable {
    case good
    case broken

    func encode(to encoder: any Encoder) throws {
        guard self != .broken else { throw TwentyThirdStorageError.encode }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private final class TwentyThirdBlockingStorage: RouterSnapshotStorage {
    let removals: AsyncStream<Void>
    let saves: AsyncStream<Void>
    private let removalContinuation: AsyncStream<Void>.Continuation
    private let saveContinuation: AsyncStream<Void>.Continuation
    private let removeBarrier = DispatchSemaphore(value: 0)
    private let saveBarrier = DispatchSemaphore(value: 0)
    private let stored = Mutex<Data?>(nil)
    private let removeFails: Bool
    private let saveFails: Bool

    init(removeFails: Bool, saveFails: Bool = false) {
        self.removeFails = removeFails
        self.saveFails = saveFails
        (removals, removalContinuation) = AsyncStream.makeStream(of: Void.self)
        (saves, saveContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        releaseRemove()
        releaseSave()
        removalContinuation.finish()
        saveContinuation.finish()
    }

    var data: Data? { stored.withLock { $0 } }
    func releaseRemove() { removeBarrier.signal() }
    func releaseSave() { saveBarrier.signal() }
    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
        saveContinuation.yield()
        guard saveBarrier.wait(timeout: .now() + 5) == .success else {
            throw TwentyThirdStorageError.timeout
        }
        guard !saveFails else { throw TwentyThirdStorageError.save }
        stored.withLock { $0 = data }
    }

    func remove() throws {
        removalContinuation.yield()
        guard removeBarrier.wait(timeout: .now() + 5) == .success else {
            throw TwentyThirdStorageError.timeout
        }
        guard !removeFails else { throw TwentyThirdStorageError.remove }
        stored.withLock { $0 = nil }
    }
}

// Synchronous storage deliberately occupies a worker while the test controls
// completion. Serialize the cases to avoid exhausting the cooperative pool.
@Suite("Twenty-third review restoration status ownership", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterTwentyThirdReviewRestorationTests {
    @Test("Old removal cannot erase a newer encode failure", arguments: [false, true], [false, true])
    func newerEncodeFailureSurvivesRemoval(active: Bool, removeFails: Bool) async throws {
        let codec = try RouterSnapshotCodec<TwentyThirdStoredRoute>(currentVersion: 1)
        let state = RouterState<TwentyThirdStoredRoute>.rootStack(path: [.broken])
        let store = RouterStore(initialState: state)
        let storage = TwentyThirdBlockingStorage(removeFails: removeFails)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        if active { #expect(try await driver.activate() == .noSnapshot) }
        let removal = Task { @MainActor in try await driver.removeSnapshot() }
        defer { storage.releaseRemove(); removal.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.removals, what: "old removal")

        await #expect(throws: RouterSnapshotError.encodePayload("encode")) {
            try await driver.save()
        }
        let newerFailure = driver.status
        #expect(newerFailure == .failed("encodePayload(\"encode\")"))
        storage.releaseRemove()
        try await verifyRemoval(removal, fails: removeFails)
        #expect(driver.status == newerFailure)
        #expect(store.state == state)
        #expect(store.revision == 0)
    }

    @Test("Old removal cannot overwrite a newer in-flight save", arguments: [false, true], [false, true])
    func newerSaveOwnsStatus(removeFails: Bool, saveFails: Bool) async throws {
        let codec = try RouterSnapshotCodec<TwentyThirdStoredRoute>(currentVersion: 1)
        let state = RouterState<TwentyThirdStoredRoute>.rootStack(path: [.good])
        let store = RouterStore(initialState: state)
        let storage = TwentyThirdBlockingStorage(removeFails: removeFails, saveFails: saveFails)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        #expect(try await driver.activate() == .noSnapshot)
        let removal = Task { @MainActor in try await driver.removeSnapshot() }
        var save: Task<Void, any Error>?
        defer {
            storage.releaseRemove()
            storage.releaseSave()
            removal.cancel()
            save?.cancel()
            driver.stop()
        }
        _ = try await firstElement(from: storage.removals, what: "old removal")
        let saving = Task { @MainActor in try await driver.save() }
        save = saving
        try await waitUntil("new save publishes saving") { driver.status == .saving }
        storage.releaseRemove()
        try await verifyRemoval(removal, fails: removeFails)
        _ = try await firstElement(from: storage.saves, what: "new save reached storage")
        #expect(driver.status == .saving)
        storage.releaseSave()
        if saveFails {
            await #expect(throws: TwentyThirdStorageError.save) { try await saving.value }
            #expect(driver.status == .failed("save"))
            #expect(storage.data == nil)
        } else {
            try await saving.value
            #expect(driver.status == .active)
            #expect(try codec.decode(#require(storage.data)) == state)
        }
        #expect(store.state == state)
        #expect(store.revision == 0)
    }

    @Test("An unsuperseded removal still reports its own result", arguments: [false, true], [false, true])
    func currentRemovalUpdatesStatus(active: Bool, removeFails: Bool) async throws {
        let codec = try RouterSnapshotCodec<TwentyThirdStoredRoute>(currentVersion: 1)
        let storage = TwentyThirdBlockingStorage(removeFails: removeFails)
        let driver = RouterRestorationDriver(store: RouterStore<TwentyThirdStoredRoute>(), codec: codec, storage: storage)
        if active { _ = try await driver.activate() }
        let removal = Task { @MainActor in try await driver.removeSnapshot() }
        defer { storage.releaseRemove(); removal.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.removals, what: "current removal")
        storage.releaseRemove()
        try await verifyRemoval(removal, fails: removeFails)
        #expect(driver.status == (removeFails ? .failed("remove") : (active ? .active : .inactive)))
    }

    @Test("Stop revokes status ownership without cancelling durable removal", arguments: [false, true])
    func stoppedRemovalCannotPublishStatus(removeFails: Bool) async throws {
        let codec = try RouterSnapshotCodec<TwentyThirdStoredRoute>(currentVersion: 1)
        let storage = TwentyThirdBlockingStorage(removeFails: removeFails)
        let driver = RouterRestorationDriver(store: RouterStore<TwentyThirdStoredRoute>(), codec: codec, storage: storage)
        _ = try await driver.activate()
        let removal = Task { @MainActor in try await driver.removeSnapshot() }
        defer { storage.releaseRemove(); removal.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.removals, what: "removal before stop")
        driver.stop()
        storage.releaseRemove()
        try await verifyRemoval(removal, fails: removeFails)
        #expect(driver.status == .inactive)
    }

    private func verifyRemoval(_ task: Task<Void, any Error>, fails: Bool) async throws {
        if fails {
            await #expect(throws: TwentyThirdStorageError.remove) { try await task.value }
        } else {
            try await task.value
        }
    }
}
