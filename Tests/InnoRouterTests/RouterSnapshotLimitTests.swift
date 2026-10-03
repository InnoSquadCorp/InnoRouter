import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

@Suite("Bounded router snapshots")
struct RouterSnapshotLimitTests {
    private enum R: String, Route, Codable {
        case home
        case detail
    }

    @Test("Codec limits accept exact boundaries and reject one byte over")
    func codecBoundaries() throws {
        let state = RouterState<R>.rootStack(path: [.home, .detail])
        let unlimited = try RouterSnapshotCodec<R>(currentVersion: 1)
        let encoded = try unlimited.encode(state)
        let envelope = try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: encoded)
        let exact = try RouterSnapshotLimits(
            maximumEncodedByteCount: encoded.count,
            maximumPayloadByteCount: envelope.payload.count
        )
        let exactCodec = try RouterSnapshotCodec<R>(currentVersion: 1, limits: exact)

        #expect(try exactCodec.encode(state) == encoded)
        #expect(try exactCodec.decode(encoded) == state)

        let encodedTooSmall = try RouterSnapshotCodec<R>(
            currentVersion: 1,
            limits: RouterSnapshotLimits(
                maximumEncodedByteCount: encoded.count - 1,
                maximumPayloadByteCount: envelope.payload.count
            )
        )
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: encoded.count,
            maximumByteCount: encoded.count - 1
        )) {
            try encodedTooSmall.decode(encoded)
        }
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: encoded.count,
            maximumByteCount: encoded.count - 1
        )) {
            try encodedTooSmall.encode(state)
        }

        let payloadTooSmall = try RouterSnapshotCodec<R>(
            currentVersion: 1,
            limits: RouterSnapshotLimits(
                maximumEncodedByteCount: encoded.count,
                maximumPayloadByteCount: envelope.payload.count - 1
            )
        )
        #expect(throws: RouterSnapshotError.payloadTooLarge(
            actualByteCount: envelope.payload.count,
            maximumByteCount: envelope.payload.count - 1
        )) {
            try payloadTooSmall.decode(encoded)
        }
        #expect(throws: RouterSnapshotError.payloadTooLarge(
            actualByteCount: envelope.payload.count,
            maximumByteCount: envelope.payload.count - 1
        )) {
            try payloadTooSmall.encode(state)
        }
    }

    @Test("Nonpositive byte limits fail explicitly", arguments: [0, -1, Int.min])
    func invalidLimits(_ value: Int) {
        #expect(throws: RouterSnapshotError.invalidByteLimit(
            name: "maximumEncodedByteCount",
            value: value
        )) {
            _ = try RouterSnapshotLimits(
                maximumEncodedByteCount: value,
                maximumPayloadByteCount: 1
            )
        }
        #expect(throws: RouterSnapshotError.invalidByteLimit(
            name: "maximumPayloadByteCount",
            value: value
        )) {
            _ = try RouterSnapshotLimits(
                maximumEncodedByteCount: 1,
                maximumPayloadByteCount: value
            )
        }
    }

    @Test("Every migration result is bounded before typed route decoding")
    func migrationOutputLimit() throws {
        let oldPayload = try JSONEncoder().encode(RouterState<R>.rootStack)
        let encoded = try JSONEncoder().encode(
            RouterSnapshotEnvelope(schemaVersion: 1, payload: oldPayload)
        )
        let codec = try RouterSnapshotCodec<R>(
            currentVersion: 2,
            migrations: [.init(from: 1, to: 2) { _ in Data(repeating: 0, count: 129) }],
            limits: RouterSnapshotLimits(
                maximumEncodedByteCount: encoded.count,
                maximumPayloadByteCount: 128
            )
        )

        #expect(throws: RouterSnapshotError.payloadTooLarge(
            actualByteCount: 129,
            maximumByteCount: 128
        )) {
            try codec.decode(encoded)
        }
        #expect(try codec.decode(encoded, recovery: .use { error in
            guard error == .payloadTooLarge(actualByteCount: 129, maximumByteCount: 128) else {
                return .rootStack(path: [.detail])
            }
            return .rootStack(path: [.home])
        }) == .recovered(
            state: .rootStack(path: [.home]),
            reason: .payloadTooLarge(actualByteCount: 129, maximumByteCount: 128)
        ))
    }

    @Test("Application migration errors keep the 6.0 wrapping contract")
    func migrationErrorCompatibility() throws {
        let oldCodec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let encoded = try oldCodec.encode(.rootStack(path: [.detail]))
        let migrationError = RouterSnapshotError.invalidSnapshotVersion(0)
        let codec = try RouterSnapshotCodec<R>(
            currentVersion: 2,
            migrations: [.init(from: 1, to: 2) { _ in throw migrationError }]
        )

        do {
            _ = try codec.decode(encoded)
            Issue.record("Expected the migration to fail")
        } catch let error as RouterSnapshotError {
            guard case .migrationFailed(let from, let to, let message) = error else {
                Issue.record("Expected the 6.0 migrationFailed wrapper, got \(error)")
                return
            }
            #expect(from == 1)
            #expect(to == 2)
            #expect(message.contains("invalidSnapshotVersion(0)"))
        }

        let recovered = try codec.decode(encoded, recovery: .use { error in
            guard case .migrationFailed = error else { return .rootStack }
            return .rootStack(path: [.home])
        })
        #expect(recovered == .recovered(
            state: .rootStack(path: [.home]),
            reason: .migrationFailed(
                from: 1,
                to: 2,
                message: String(describing: migrationError)
            )
        ))
    }

    @Test("Bounded file storage reads multiple chunks and preserves an existing file on rejection")
    func boundedFileStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "router.snapshot")
        let maximum = 128 * 1_024
        let storage = try RouterFileSnapshotStorage(
            fileURL: url,
            maximumByteCount: maximum
        )
        let exact = Data(repeating: 7, count: maximum)
        try storage.save(exact)
        #expect(try storage.load() == exact)

        let oversized = Data(repeating: 8, count: maximum + 1)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: maximum + 1,
            maximumByteCount: maximum
        )) {
            try storage.save(oversized)
        }
        #expect(try Data(contentsOf: url) == exact)

        try oversized.write(to: url, options: .atomic)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: maximum + 1,
            maximumByteCount: maximum
        )) {
            try storage.load()
        }
    }

    @Test("Bounded file reads enforce the stream after metadata changes")
    func boundedFileMutationDuringLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "router.snapshot")
        let maximum = 128 * 1_024
        let exact = Data(repeating: 7, count: maximum)
        let oversized = Data(repeating: 8, count: maximum + 1)
        let smaller = Data(repeating: 9, count: maximum / 2)
        let storage = try RouterFileSnapshotStorage(fileURL: url, maximumByteCount: maximum)

        try exact.write(to: url, options: .atomic)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: maximum + 1,
            maximumByteCount: maximum
        )) {
            try RouterByteStoreTestSupport.$afterBoundedFileMetadataRead.withValue({
                try oversized.write(to: url, options: .atomic)
            }) {
                try storage.load()
            }
        }

        try exact.write(to: url, options: .atomic)
        let loaded = try RouterByteStoreTestSupport.$afterBoundedFileMetadataRead.withValue({
            try smaller.write(to: url, options: .atomic)
        }) {
            try storage.load()
        }
        #expect(loaded == smaller)
    }

    @Test("The largest byte limit does not overflow")
    func maximumIntegerLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "router.snapshot")
        let data = Data("bounded snapshot".utf8)
        let storage = try RouterFileSnapshotStorage(fileURL: url, maximumByteCount: Int.max)

        try storage.save(data)
        #expect(try storage.load() == data)
    }

    @Test("Bounded file storage rejects invalid limits")
    func invalidStorageLimit() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(throws: RouterSnapshotError.invalidByteLimit(
            name: "maximumByteCount",
            value: 0
        )) {
            _ = try RouterFileSnapshotStorage(fileURL: url, maximumByteCount: 0)
        }
    }

    @Test("Oversized direct, partial, and driver restores preserve state and files")
    @MainActor
    func restorationBoundaries() async throws {
        let savedState = RouterState<R>.rootStack(path: [.detail])
        let unlimited = try RouterSnapshotCodec<R>(currentVersion: 1)
        let encoded = try unlimited.encode(savedState)
        let limited = try RouterSnapshotCodec<R>(
            currentVersion: 1,
            limits: RouterSnapshotLimits(
                maximumEncodedByteCount: encoded.count - 1,
                maximumPayloadByteCount: encoded.count
            )
        )
        let store = RouterStore(initialState: RouterState<R>.rootStack(path: [.home]))
        let initial = store.state

        await #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: encoded.count,
            maximumByteCount: encoded.count - 1
        )) {
            try await store.restore(from: encoded, using: limited)
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)

        await #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: encoded.count,
            maximumByteCount: encoded.count - 1
        )) {
            try await store.restorePartially(
                from: encoded,
                using: limited,
                validator: .init { _, _ in .keep }
            )
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "router.snapshot")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded.write(to: url)
        let driver = RouterRestorationDriver(
            store: store,
            codec: unlimited,
            storage: try RouterFileSnapshotStorage(
                fileURL: url,
                maximumByteCount: encoded.count - 1
            )
        )
        defer { driver.stop() }

        await #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: encoded.count,
            maximumByteCount: encoded.count - 1
        )) {
            try await driver.activate()
        }
        guard case .failed = driver.status else {
            Issue.record("The driver must expose the bounded storage failure")
            return
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(try Data(contentsOf: url) == encoded)
    }

    // A storage byte limit rejects the snapshot before the codec reads it. The
    // codec's own limit check raises the same typed error and reaches the
    // recovery policy, so a storage rejection must reach it too instead of
    // failing activation on every launch.
    @Test("A bounded storage rejection reaches the driver's recovery policy")
    @MainActor
    func storageRejectionUsesRecoveryPolicy() async throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let encoded = try codec.encode(.rootStack(path: [.detail]))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "router.snapshot")
        try encoded.write(to: url)
        let fallback = RouterState<R>.rootStack(path: [.home])
        let store = RouterStore<R>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: try RouterFileSnapshotStorage(
                fileURL: url,
                maximumByteCount: encoded.count - 1
            ),
            recovery: .use { _ in fallback }
        )
        defer { driver.stop() }

        let activation = try await driver.activate()

        guard case .restored(let outcome) = activation else {
            Issue.record("Expected the recovery fallback to restore, got \(activation)")
            return
        }
        #expect(outcome.decoding == .recovered(
            state: fallback,
            reason: .encodedDataTooLarge(
                actualByteCount: encoded.count,
                maximumByteCount: encoded.count - 1
            )
        ))
        guard case .applied = outcome.transition else {
            Issue.record("Expected the fallback to apply, got \(outcome.transition)")
            return
        }
        #expect(store.state == fallback)
        #expect(driver.status == .active)
    }

    // Only a typed snapshot rejection is recoverable. An environmental failure
    // says nothing about the stored snapshot, and applying the fallback would
    // let the next save overwrite a file that may still be readable.
    @Test("An untyped storage failure never reaches the recovery policy")
    @MainActor
    func untypedStorageFailureSkipsRecoveryPolicy() async throws {
        let store = RouterStore(initialState: RouterState<R>.rootStack(path: [.detail]))
        let initial = store.state
        let driver = RouterRestorationDriver(
            store: store,
            codec: try RouterSnapshotCodec<R>(currentVersion: 1),
            storage: UnavailableSnapshotStorage(),
            recovery: .use { _ in .rootStack(path: [.home]) }
        )
        defer { driver.stop() }

        await #expect(throws: UnavailableSnapshotStorage.Unavailable.self) {
            try await driver.activate()
        }
        guard case .failed = driver.status else {
            Issue.record("The driver must expose the storage failure")
            return
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)
    }

    @Test("A failed mounted restore cannot be replaced by a lifecycle save")
    @MainActor
    func failedRestoreLifecycleSave() async throws {
        let savedState = RouterState<R>.rootStack(path: Array(repeating: .detail, count: 100))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let encoded = try codec.encode(savedState)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "router.snapshot")
        try encoded.write(to: url)
        let store = RouterStore<R>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: try RouterFileSnapshotStorage(
                fileURL: url,
                maximumByteCount: encoded.count - 1
            )
        )
        let attachmentID = UUID()
        defer {
            driver.detach(attachmentID)
            driver.stop()
        }

        await #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: encoded.count,
            maximumByteCount: encoded.count - 1
        )) {
            try await driver.attach(attachmentID)
        }
        guard case .failed = driver.status else {
            Issue.record("Expected the restore failure to remain visible")
            return
        }

        await driver.saveForSceneLifecycle(attachmentID: attachmentID)
        #expect(try Data(contentsOf: url) == encoded)
        #expect(store.revision == 0)
        guard case .failed = driver.status else {
            Issue.record("A skipped lifecycle save must preserve the restore failure")
            return
        }

        _ = await store.perform(.push(.home))
        await driver.saveForSceneLifecycle(attachmentID: attachmentID)
        let saved = try Data(contentsOf: url)
        #expect(try codec.decode(saved) == .rootStack(path: [.home]))
        #expect(store.revision == 1)
    }
}

private struct UnavailableSnapshotStorage: RouterSnapshotStorage {
    struct Unavailable: Error {}

    func load() throws -> Data? { throw Unavailable() }
    func save(_ data: Data) throws {}
    func remove() throws {}
}
