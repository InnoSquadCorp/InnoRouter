import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Persistence cannot widen its Store resource owner", .timeLimit(.minutes(1)))
@MainActor
struct RouterPersistenceOwnerBudgetTests {
    private struct Screen: Route { let value: String }
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }
    private struct Legacy: Route, Codable {
        static let decodes = Mutex(0)
        let value: String
        init(value: String) { self.value = value }
        init(from decoder: any Decoder) throws {
            Self.decodes.withLock { $0 += 1 }
            value = try decoder.singleValueContainer().decode(String.self)
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
    private func graph(_ counter: Counter, bytes: Int = 65_536) throws -> RouterGraphSnapshotCodec<Screen> {
        try .init(schemaID: "owner", schemaVersion: 1, routes: .init(
            supportedPayloadVersions: ["screen": 1],
            encode: { .init(stableKey: "screen", payloadVersion: 1, data: Data($0.value.utf8)) },
            decode: { payload in
                counter.increment()
                return Screen(value: String(decoding: payload.data, as: UTF8.self))
            }
        ), limits: .init(maximumRoutePayloadBytes: bytes))
    }
    private func budget(bytes: Int = 1, work: Int? = nil) throws -> RouterResourceBudget {
        .init(snapshot: try .init(maximumRoutePayloadBytes: bytes), maximumJSONWorkUnits: work)
    }

    @Test("A broad graph codec cannot enter its decoder beyond the Store route-byte cap", arguments: [false, true])
    func graphOwnerBeforeDecoder(driver: Bool) async throws {
        let counter = Counter()
        let codec = try graph(counter)
        let target = RouterState<Screen>.rootStack(path: [.init(value: "42")])
        let bytes = try codec.encode(target)
        let store = try RouterStore<Screen>(configuration: .init(resourceBudget: budget()))
        if driver {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = RouterFileSnapshotStorage(fileURL: directory.appending(path: "state.json"))
            try storage.save(bytes)
            let driver = RouterRestorationDriver(store: store, graphCodec: codec, storage: storage)
            await #expect(throws: RouterGraphSnapshotError.self) { try await driver.activate() }
            #expect(try storage.load() == bytes)
            driver.stop()
        } else {
            await #expect(throws: RouterGraphSnapshotError.self) { try await store.restore(from: bytes, using: codec) }
        }
        #expect(counter.count == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(try codec.decode(bytes) == target)
        #expect(counter.count == 1)
    }

    @Test("Explicit standalone legacy opt-out cannot bypass the Store's decoder byte admission")
    func legacyOwnerBeforeDecoder() async throws {
        Legacy.decodes.withLock { $0 = 0 }
        let codec = try RouterSnapshotCodec<Legacy>(currentVersion: 17, limits: nil)
        let target = RouterState<Legacy>.rootStack(path: [.init(value: "long-payload")])
        let data = try codec.encode(target)
        let store = try RouterStore<Legacy>(configuration: .init(resourceBudget: budget()))
        await #expect(throws: RouterSnapshotError.self) { try await store.restore(from: data, using: codec) }
        #expect(Legacy.decodes.withLock { $0 } == 0)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(try codec.decode(data) == target)
        #expect(Legacy.decodes.withLock { $0 } == 1)
    }

    @Test("A larger Store budget preserves stricter codec limits")
    func codecRemainsStrict() async throws {
        let counter = Counter()
        let broad = try graph(counter)
        let strict = try graph(counter, bytes: 1)
        let data = try broad.encode(.rootStack(path: [.init(value: "42")]))
        let store = try RouterStore<Screen>(configuration: .init(resourceBudget: budget(bytes: 64)))
        await #expect(throws: RouterGraphSnapshotError.self) { try await store.restore(from: data, using: strict) }
        #expect(counter.count == 0)
        #expect(store.state == .rootStack)
    }

    @Test("Store logical-work zero rejects before graph application callbacks")
    func ownerWorkCap() async throws {
        let counter = Counter()
        let codec = try graph(counter)
        let data = try codec.encode(.rootStack(path: [.init(value: "42")]))
        let store = try RouterStore<Screen>(configuration: .init(resourceBudget: budget(bytes: 64, work: 0)))
        await #expect(throws: RouterGraphSnapshotError.self) { try await store.restore(from: data, using: codec) }
        #expect(counter.count == 0)
        #expect(store.revision == 0)
    }
}
