import Foundation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum StorageCancellationRoute: String, Route, Codable {
    case saved, current, replacement
}

private enum NewStorageCommand: CaseIterable, Sendable {
    case navigation, explicitSave, remove
}

private final class SuspendedSnapshotFile: RouterSnapshotStorage {
    let file: RouterFileSnapshotStorage
    let loads: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)
    private let writes = Mutex(0)

    init(url: URL) {
        file = RouterFileSnapshotStorage(fileURL: url)
        (loads, loadContinuation) = AsyncStream.makeStream()
    }

    var writeCount: Int { writes.withLock { $0 } }
    func unblock() { release.signal() }

    func load() throws -> Data? {
        let data = try file.load()
        loadContinuation.yield(())
        guard release.wait(timeout: .now() + 10) == .success else {
            throw RouterTestWaitFailure.conditionNotMet("release file load", timeout: .seconds(10))
        }
        return data
    }

    func save(_ data: Data) throws {
        try file.save(data)
        writes.withLock { $0 += 1 }
    }

    func remove() throws { try file.remove() }
}

@Suite("Restoration storage cancellation", .timeLimit(.minutes(1)))
@MainActor
struct RouterRestorationStorageCancellationTests {
    private typealias R = StorageCancellationRoute

    @Test("A revoked queued save cannot overwrite its replacement", arguments: [false, true], [false, true])
    func replacementPreserved(lifecycle: Bool, detach: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "snapshot.json")
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        try RouterFileSnapshotStorage(fileURL: url).save(codec.encode(.rootStack(path: [.saved])))
        let storage = SuspendedSnapshotFile(url: url)
        let (enqueued, didEnqueue) = AsyncStream<Void>.makeStream()
        let (finished, didFinish) = AsyncStream<Void>.makeStream()
        var configuration = RouterStoreConfiguration<R>()
        configuration.runtimeDependencies.willEnqueueRestorationSave = { didEnqueue.yield(()) }
        configuration.runtimeDependencies.didFinishRestorationSave = { didFinish.yield(()) }
        let store = RouterStore<R>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store, codec: codec, storage: storage,
            saveDebounce: lifecycle ? .seconds(3_600) : .zero
        )
        let attachment = UUID()
        let activation = Task { try await driver.attach(attachment) }
        var flush: Task<Void, Never>?
        defer {
            storage.unblock(); activation.cancel(); flush?.cancel(); driver.stop()
            didEnqueue.finish(); didFinish.finish()
        }
        _ = try await firstElement(from: storage.loads, what: "load holds storage actor")
        _ = await store.perform(.push(.current))
        if lifecycle { flush = Task { await driver.saveForSceneLifecycle(attachmentID: attachment) } }
        _ = try await firstElement(from: enqueued, what: "save enqueued at occupied storage actor")
        #expect(storage.writeCount == 0)

        if detach { driver.detach(attachment) } else { driver.stop() }
        let replacement = RouterStore(initialState: RouterState<R>.rootStack(path: [.replacement]))
        let replacementDriver = RouterRestorationDriver(
            store: replacement, codec: codec, storage: RouterFileSnapshotStorage(fileURL: url)
        )
        defer { replacementDriver.stop() }
        try await replacementDriver.save()
        let replacementBytes = try Data(contentsOf: url)
        #expect(try codec.decode(replacementBytes) == replacement.state)

        storage.unblock()
        _ = try? await activation.value
        _ = try await firstElement(from: finished, what: "revoked save finished without writing")
        await flush?.value
        #expect(storage.writeCount == 0)
        #expect(try Data(contentsOf: url) == replacementBytes)
        #expect(driver.status == .inactive)
        #expect(store.revision == 1)
    }

    @Test("An explicit save still finishes after stop and caller cancellation")
    func explicitSaveKeepsDurability() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "snapshot.json")
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        try RouterFileSnapshotStorage(fileURL: url).save(codec.encode(.rootStack(path: [.saved])))
        let storage = SuspendedSnapshotFile(url: url)
        let (enqueued, didEnqueue) = AsyncStream<Void>.makeStream()
        var configuration = RouterStoreConfiguration<R>()
        configuration.runtimeDependencies.willEnqueueRestorationSave = { didEnqueue.yield(()) }
        let store = RouterStore(initialState: RouterState<R>.rootStack(path: [.current]), configuration: configuration)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { try await driver.activate() }
        var saving: Task<Void, any Error>?
        defer { storage.unblock(); activation.cancel(); saving?.cancel(); driver.stop(); didEnqueue.finish() }
        _ = try await firstElement(from: storage.loads, what: "load before explicit save")
        let request = Task { try await driver.save() }
        saving = request
        _ = try await firstElement(from: enqueued, what: "explicit save enqueued")
        driver.stop()
        request.cancel()
        storage.unblock()
        _ = try? await activation.value
        try await request.value
        #expect(storage.writeCount == 1)
        #expect(try codec.decode(Data(contentsOf: url)) == store.state)
        #expect(driver.status == .inactive)
    }

    @Test("New commands supersede queued automatic writes", arguments: NewStorageCommand.allCases)
    private func newerCommandWins(command: NewStorageCommand) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "snapshot.json")
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        try RouterFileSnapshotStorage(fileURL: url).save(codec.encode(.rootStack(path: [.saved])))
        let storage = SuspendedSnapshotFile(url: url)
        let (enqueued, didEnqueue) = AsyncStream<Void>.makeStream()
        let (finished, didFinish) = AsyncStream<Void>.makeStream()
        let (reservations, didReserve) = AsyncStream<RouterDurabilityReservation>.makeStream()
        var configuration = RouterStoreConfiguration<R>()
        configuration.runtimeDependencies.willEnqueueRestorationSave = { didEnqueue.yield(()) }
        configuration.runtimeDependencies.didFinishRestorationSave = { didFinish.yield(()) }
        let store = RouterStore<R>(configuration: configuration)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage, saveDebounce: .zero)
        let activation = Task { try await driver.activate() }
        var next: Task<Void, any Error>?
        defer {
            storage.unblock(); activation.cancel(); next?.cancel(); driver.stop()
            didEnqueue.finish(); didFinish.finish(); didReserve.finish()
        }
        _ = try await firstElement(from: storage.loads, what: "load before superseding save")
        _ = await store.perform(.push(.current))
        _ = try await firstElement(from: enqueued, what: "old automatic save queued")

        let request = Task {
            try await RouterDurabilityTestSupport.withReservationObserver({ didReserve.yield($0) }) {
                switch command {
                case .navigation: _ = await store.perform(.push(.replacement))
                case .explicitSave: try await driver.save()
                case .remove: try await driver.removeSnapshot()
                }
            }
        }
        next = request
        _ = try await firstElement(from: reservations, what: "new durable command reserved")
        #expect(storage.writeCount == 0)
        storage.unblock()
        _ = try await activation.value
        try await request.value
        _ = try await firstElement(from: finished, what: "superseded save finished")
        if command == .remove {
            #expect(storage.writeCount == 0)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else {
            _ = try await firstElement(from: finished, what: "current save finished")
            #expect(storage.writeCount == 1)
            #expect(try codec.decode(Data(contentsOf: url)) == store.state)
        }
    }
}
