import Foundation
import Synchronization
import Testing

import InnoRouterCore

@Suite("Explicit legacy to graph migration")
struct RouterLegacyGraphAdapterPortableContractTests {
    private enum Old: String, Route, Codable { case oldHome }
    private struct New: Route { let value: Int }
    private enum MappingFailure: Error { case rejected }
    private final class Counter: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func increment() { value.withLock { $0 += 1 } }
    }

    private func codec(
        legacy: RouterSnapshotCodec<Old>,
        calls: Counter,
        rejects: Bool = false
    ) throws -> RouterGraphSnapshotCodec<New> {
        let adapter = RouterLegacySnapshotAdapter<New>(codec: legacy) { state in
            calls.increment()
            if rejects { throw MappingFailure.rejected }
            guard case .stack(let stack) = state.root, state.windows.isEmpty, state.immersiveSpace == nil else {
                throw MappingFailure.rejected
            }
            return .rootStack(path: stack.path.map { _ in .init(value: 9) })
        }
        let routes = try RouterGraphRouteCodec<New>(supportedPayloadVersions: ["home.stable": 4]) { route in
            .init(stableKey: "home.stable", payloadVersion: 4, data: Data(String(route.value).utf8))
        } decode: { payload in
            guard let value = Int(String(decoding: payload.data, as: UTF8.self)) else { throw MappingFailure.rejected }
            return .init(value: value)
        }
        return try .init(schemaID: "renamed.application", schemaVersion: 3, routes: routes, legacyAdapter: adapter)
    }

    @Test("An actual app version seventeen migrates through the declared rename transform")
    func explicitAppVersionAndRename() throws {
        let legacy = try RouterSnapshotCodec<Old>(currentVersion: 17)
        let original = try legacy.encode(.rootStack(path: [.oldHome]))
        let copy = original
        let calls = Counter()
        let graph = try codec(legacy: legacy, calls: calls)
        let state = try graph.decode(original)
        #expect(state == .rootStack(path: [.init(value: 9)]))
        #expect(calls.count == 1)
        #expect(original == copy)
        let newBytes = try graph.encode(state)
        #expect(try graph.decode(newBytes) == state)
        #expect(calls.count == 1)
        let envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: newBytes)
        #expect(envelope.formatVersion == 1)
        #expect(envelope.schemaID == "renamed.application")
        #expect(envelope.schemaVersion == 3)
    }

    @Test("Any graph-format marker owns dispatch; malformed markers never fall back", arguments: ["null", "\"one\"", "2", "{}"])
    func noCorruptGraphFallback(marker: String) throws {
        let legacy = try RouterSnapshotCodec<Old>(currentVersion: 17)
        let encoded = try legacy.encode(.rootStack(path: [.oldHome]))
        let text = String(decoding: encoded.dropLast(), as: UTF8.self)
        let data = Data((text + ",\"formatVersion\":" + marker + "}").utf8)
        let calls = Counter()
        let graph = try codec(legacy: legacy, calls: calls)
        #expect(throws: RouterGraphSnapshotError.self) { try graph.decode(data) }
        #expect(calls.count == 0)
    }

    @Test("No explicit legacy adapter means legacy bytes fail closed")
    func optInIsRequired() throws {
        let legacy = try RouterSnapshotCodec<Old>(currentVersion: 17)
        let data = try legacy.encode(.rootStack(path: [.oldHome]))
        let routes = try RouterGraphRouteCodec<Old>(supportedPayloadVersions: ["home": 1]) { _ in
            .init(stableKey: "home", payloadVersion: 1, data: Data())
        } decode: { _ in .oldHome }
        let graph = try RouterGraphSnapshotCodec(schemaID: "app", schemaVersion: 1, routes: routes)
        #expect(throws: RouterGraphSnapshotError.invalidEnvelope) { try graph.decode(data) }
    }

    @Test("App mapping failure is a payload-free value and preserves original bytes")
    func rejectedMapping() throws {
        let legacy = try RouterSnapshotCodec<Old>(currentVersion: 17)
        let data = try legacy.encode(.rootStack(path: [.oldHome]))
        let calls = Counter()
        let graph = try codec(legacy: legacy, calls: calls, rejects: true)
        #expect(throws: RouterGraphSnapshotError.legacyRouteMappingFailed) { try graph.decode(data) }
        #expect(calls.count == 1)
        #expect(try legacy.decode(data) == .rootStack(path: [.oldHome]))
        #expect(!RouterGraphSnapshotError.legacyRouteMappingFailed.description.contains("oldHome"))
    }

    @Test("An explicitly unbounded old codec cannot bypass the graph adapter's payload bound")
    func legacyReaderCannotDisableBounds() throws {
        let legacy = try RouterSnapshotCodec<Old>(currentVersion: 17, limits: nil)
        let state = try JSONEncoder().encode(RouterState<Old>.rootStack(path: [.oldHome]))
        let huge = Data((String(decoding: state.dropLast(), as: UTF8.self)
            + ",\"ignored\":\"" + String(repeating: "x", count: 2 * 1_024 * 1_024) + "\"}").utf8)
        let data = try JSONEncoder().encode(RouterSnapshotEnvelope(schemaVersion: 17, payload: huge))
        #expect(data.count < 4 * 1_024 * 1_024)
        #expect(try legacy.decode(data) == .rootStack(path: [.oldHome]))
        let calls = Counter()
        let graph = try codec(legacy: legacy, calls: calls)
        #expect(throws: RouterGraphSnapshotError.legacySnapshotRejected) { try graph.decode(data) }
        #expect(calls.count == 0)
    }
}
