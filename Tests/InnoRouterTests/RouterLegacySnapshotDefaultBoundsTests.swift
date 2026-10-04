import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

/// Deliberately uses only the pre-bounds API so these fixtures also compile
/// against the prior production codec. Unknown fields are valid JSON and are
/// ignored by the original Codable models, isolating each missing bound.
@Suite("Legacy snapshot default bounds")
struct RouterLegacySnapshotDefaultBoundsTests {
    private enum R: String, Route, Codable { case home }

    private func payload(ignoredJSON: String? = nil) throws -> Data {
        let data = try JSONEncoder().encode(RouterState<R>.rootStack(path: [.home]))
        guard let ignoredJSON else { return data }
        return Data((String(decoding: data.dropLast(), as: UTF8.self)
            + ",\"ignored\":" + ignoredJSON + "}").utf8)
    }

    private func envelope(_ payload: Data, ignoredJSON: String? = nil) throws -> Data {
        let data = try JSONEncoder().encode(RouterSnapshotEnvelope(schemaVersion: 1, payload: payload))
        guard let ignoredJSON else { return data }
        return Data((String(decoding: data.dropLast(), as: UTF8.self)
            + ",\"ignored\":" + ignoredJSON + "}").utf8)
    }

    private func excessiveJSON(_ kind: String) -> String {
        switch kind {
        case "bytes": "\"" + String(repeating: "x", count: 2 * 1_024 * 1_024) + "\""
        case "depth": String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)
        default: "[" + Array(repeating: "0", count: 131_072).joined(separator: ",") + "]"
        }
    }

    @Test("Default encoded cap rejects a valid envelope over four MiB")
    func defaultEncodedCap() throws {
        let data = try envelope(payload(), ignoredJSON: "\"" + String(repeating: "x", count: 4 * 1_024 * 1_024) + "\"")
        #expect(data.count > 4 * 1_024 * 1_024)
        let raw = try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: data)
        #expect(try JSONDecoder().decode(RouterState<R>.self, from: raw.payload) == .rootStack(path: [.home]))
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<R>(currentVersion: 1).decode(data)
        }
    }

    @Test("Default payload limits reject valid ignored data", arguments: ["bytes", "depth", "tokens"])
    func defaultPayloadBounds(kind: String) throws {
        let original = try payload(ignoredJSON: excessiveJSON(kind))
        let data = try envelope(original)
        #expect(data.count < 4 * 1_024 * 1_024)
        #expect(try JSONDecoder().decode(RouterState<R>.self, from: original) == .rootStack(path: [.home]))
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<R>(currentVersion: 1).decode(data)
        }
        #expect(try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: data).payload == original)
    }

    @Test("Default envelope complexity is checked before typed decoding", arguments: ["depth", "tokens"])
    func defaultEnvelopeBounds(kind: String) throws {
        let data = try envelope(payload(), ignoredJSON: excessiveJSON(kind))
        #expect(data.count < 4 * 1_024 * 1_024)
        #expect(try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: data).schemaVersion == 1)
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<R>(currentVersion: 1).decode(data)
        }
    }

    @Test("Every migration output is screened before the next transform", arguments: ["bytes", "depth", "tokens"])
    func intermediateMigrationBounds(kind: String) throws {
        let valid = try payload()
        let original = try envelope(valid)
        let invalid = try payload(ignoredJSON: excessiveJSON(kind))
        let calls = Mutex<[Int]>([])
        let codec = try RouterSnapshotCodec<R>(currentVersion: 3, migrations: [
            .init(from: 1, to: 2) { _ in calls.withLock { $0.append(1) }; return invalid },
            .init(from: 2, to: 3) { _ in calls.withLock { $0.append(2) }; return valid },
        ])
        #expect(throws: RouterSnapshotError.self) { try codec.decode(original) }
        #expect(calls.withLock { $0 } == [1])
        #expect(try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: original).payload == valid)
    }

    @Test("The final migration output cannot bypass default bounds", arguments: ["bytes", "depth", "tokens"])
    func finalMigrationBounds(kind: String) throws {
        let original = try envelope(payload())
        let invalid = try payload(ignoredJSON: excessiveJSON(kind))
        #expect(try JSONDecoder().decode(RouterState<R>.self, from: invalid) == .rootStack(path: [.home]))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 2, migrations: [
            .init(from: 1, to: 2) { _ in invalid },
        ])
        #expect(throws: RouterSnapshotError.self) { try codec.decode(original) }
    }

    @Test("Duplicate keys are rejected even when Foundation ignores them", arguments: [false, true])
    func duplicateKeys(inPayload: Bool) throws {
        let valid = try payload()
        let duplicateFields = ",\"ignored\":1,\"\\u0069gnored\":2}"
        let data: Data
        if inPayload {
            let duplicate = Data((String(decoding: valid.dropLast(), as: UTF8.self) + duplicateFields).utf8)
            #expect(try JSONDecoder().decode(RouterState<R>.self, from: duplicate) == .rootStack(path: [.home]))
            data = try envelope(duplicate)
        } else {
            data = Data((String(decoding: try envelope(valid).dropLast(), as: UTF8.self) + duplicateFields).utf8)
            #expect(try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: data).payload == valid)
        }
        #expect(throws: RouterSnapshotError.self) {
            try RouterSnapshotCodec<R>(currentVersion: 1).decode(data)
        }
    }

    @Test("Valid legacy state and adjacent JSON migrations remain independent controls")
    func validControls() throws {
        let valid = try payload()
        let data = try envelope(valid)
        #expect(try RouterSnapshotCodec<R>(currentVersion: 1).decode(data) == .rootStack(path: [.home]))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 3, migrations: [
            .init(from: 1, to: 2) { $0 }, .init(from: 2, to: 3) { $0 },
        ])
        #expect(try codec.decode(data) == .rootStack(path: [.home]))
    }
}
