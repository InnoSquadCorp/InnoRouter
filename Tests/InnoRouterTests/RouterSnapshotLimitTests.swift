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
}
