import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

@Suite("Legacy snapshot preflight contracts")
struct RouterLegacySnapshotPreflightTests {
    private enum R: String, Route, Codable { case home }
    private enum TextRoute: Route, Codable { case text(String) }
    private enum DecodeProbe: Route, Codable {
        case home
        static let calls = Mutex(0)

        init(from decoder: any Decoder) throws {
            Self.calls.withLock { $0 += 1 }
            _ = try decoder.singleValueContainer().decode(String.self)
            self = .home
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode("home")
        }
    }

    private struct MigrationDecodeProbe: Decodable, Sendable {
        static let calls = Mutex(0)
        init(from _: any Decoder) { Self.calls.withLock { $0 += 1 } }
    }

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

    private func diagnostic(
        _ code: RouterSnapshotPreflightError.Code, stage: String? = nil, version: Int? = nil,
        field: String? = nil, value: Int? = nil, actual: Int? = nil, maximum: Int? = nil
    ) -> RouterSnapshotError {
        .preflight(.init(code: code, details: .init(
            stage: stage, version: version, field: field, value: value, actual: actual, maximum: maximum
        )))
    }

    @Test("Provisional defaults are finite and explicit nil opts out")
    func defaultsAndOptOut() throws {
        let limits = RouterSnapshotLimits.provisional
        #expect(limits.maximumEncodedByteCount == 4 * 1_024 * 1_024)
        #expect(limits.maximumPayloadByteCount == 2 * 1_024 * 1_024)
        #expect(limits.maximumJSONDepth == 128)
        #expect(limits.maximumJSONTokens == 262_144)
        var data = try envelope(payload())
        data.append(Data(repeating: 32, count: limits.maximumEncodedByteCount + 1 - data.count))
        #expect(try RouterSnapshotCodec<R>(currentVersion: 1, limits: nil).decode(data) == .rootStack(path: [.home]))
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: data.count, maximumByteCount: limits.maximumEncodedByteCount
        )) { try RouterSnapshotCodec<R>(currentVersion: 1).decode(data) }
    }

    @Test("Default byte boundaries accept exact size and reject one byte over", arguments: [false, true])
    func byteBoundaries(inPayload: Bool) throws {
        let limits = RouterSnapshotLimits.provisional
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let maximum = inPayload ? limits.maximumPayloadByteCount : limits.maximumEncodedByteCount
        var bytes = try inPayload ? payload() : envelope(payload())
        bytes.append(Data(repeating: 32, count: maximum - bytes.count))
        #expect(try codec.decode(inPayload ? envelope(bytes) : bytes) == .rootStack(path: [.home]))
        bytes.append(32)
        let expected: RouterSnapshotError = inPayload
            ? .payloadTooLarge(actualByteCount: maximum + 1, maximumByteCount: maximum)
            : .encodedDataTooLarge(actualByteCount: maximum + 1, maximumByteCount: maximum)
        #expect(throws: expected) { try codec.decode(inPayload ? envelope(bytes) : bytes) }
    }

    @Test("Default JSON depth is inclusive for envelope and payload", arguments: [false, true])
    func depthBoundaries(inPayload: Bool) throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        for count in [126, 127, 128] {
            let ignored = String(repeating: "[", count: count) + "0" + String(repeating: "]", count: count)
            let data = try inPayload ? envelope(payload(ignoredJSON: ignored)) : envelope(payload(), ignoredJSON: ignored)
            if count < 128 {
                #expect(try codec.decode(data) == .rootStack(path: [.home]))
            } else {
                #expect(throws: diagnostic(
                    .limitExceeded, stage: inPayload ? "payload" : "envelope", version: inPayload ? 1 : nil,
                    field: "jsonDepth", actual: 129, maximum: 128
                )) { try codec.decode(data) }
            }
        }
    }

    @Test("Default JSON token boundary counts punctuation as well as scalar values")
    func tokenBoundaries() throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let encodedPayload = try payload().base64EncodedString()
        // Nine tokens for the two-field envelope, plus 2*n+5 for the
        // additional nonempty array member: exactly 262,144 when n=131,065.
        for count in [131_064, 131_065, 131_066] {
            let array = Array(repeating: "0", count: count).joined(separator: ",")
            let data = Data("{\"schemaVersion\":1,\"payload\":\"\(encodedPayload)\",\"ignored\":[\(array)]}".utf8)
            if count <= 131_065 {
                #expect(try codec.decode(data) == .rootStack(path: [.home]))
            } else {
                #expect(throws: diagnostic(
                    .limitExceeded, stage: "envelope", field: "jsonTokens", actual: 262_145, maximum: 262_144
                )) { try codec.decode(data) }
            }
        }
    }

    @Test("Encoding obeys the same finite payload bounds as decoding")
    func encodingBounds() throws {
        let state = RouterState<TextRoute>.rootStack(path: [.text(String(repeating: "x", count: 2 * 1_024 * 1_024))])
        let expectedCount = try JSONEncoder().encode(state).count
        let bounded = try RouterSnapshotCodec<TextRoute>(currentVersion: 1)
        #expect(throws: RouterSnapshotError.payloadTooLarge(
            actualByteCount: expectedCount, maximumByteCount: 2 * 1_024 * 1_024
        )) { try bounded.encode(state) }
        let unbounded = try RouterSnapshotCodec<TextRoute>(currentVersion: 1, limits: nil)
        #expect(try unbounded.decode(unbounded.encode(state)) == state)
        let shallow = try RouterSnapshotCodec<R>(currentVersion: 1, limits: RouterSnapshotLimits(
            maximumEncodedByteCount: 4_096, maximumPayloadByteCount: 4_096, maximumJSONDepth: 1
        ))
        #expect(throws: diagnostic(
            .limitExceeded, stage: "payload", version: 1, field: "jsonDepth", actual: 2, maximum: 1
        )) { try shallow.encode(.rootStack(path: [.home])) }
    }

    @Test("Payload preflight precedes application route and typed migration decoders")
    func decodersRemainUncalled() throws {
        DecodeProbe.calls.withLock { $0 = 0 }
        MigrationDecodeProbe.calls.withLock { $0 = 0 }
        let valid = try payload()
        let duplicate = Data((String(decoding: valid.dropLast(), as: UTF8.self)
            + ",\"private-key\":0,\"private-key\":1}").utf8)
        let data = try envelope(duplicate)
        let expected = diagnostic(.duplicateJSONKey, stage: "payload", version: 1)
        let codec = try RouterSnapshotCodec<DecodeProbe>(currentVersion: 1)
        #expect(throws: expected) { try codec.decode(data) }
        #expect(DecodeProbe.calls.withLock { $0 } == 0)
        let migrating = try RouterSnapshotCodec<R>(currentVersion: 2, migrations: [
            .codable(from: 1, to: 2, decoding: MigrationDecodeProbe.self) { _ in RouterState<R>.rootStack },
        ])
        #expect(throws: expected) { try migrating.decode(data) }
        #expect(MigrationDecodeProbe.calls.withLock { $0 } == 0)
        #expect(try codec.decode(envelope(valid)) == .rootStack(path: [.home]))
        #expect(DecodeProbe.calls.withLock { $0 } == 1)
        #expect(try migrating.decode(envelope(valid)) == .rootStack)
        #expect(MigrationDecodeProbe.calls.withLock { $0 } == 1)
        // Explicit nil retains the old parser path and does not claim bounds.
        #expect(try RouterSnapshotCodec<DecodeProbe>(currentVersion: 1, limits: nil).decode(data) == .rootStack(path: [.home]))
        #expect(DecodeProbe.calls.withLock { $0 } == 2)
    }

    @Test("Nonpositive JSON limits are typed and payload-free", arguments: [0, -1, Int.min])
    func invalidComplexityLimits(_ value: Int) {
        #expect(throws: diagnostic(.invalidLimit, field: "maximumJSONDepth", value: value)) {
            try RouterSnapshotLimits(maximumEncodedByteCount: 1, maximumPayloadByteCount: 1, maximumJSONDepth: value)
        }
        #expect(throws: diagnostic(.invalidLimit, field: "maximumJSONTokens", value: value)) {
            try RouterSnapshotLimits(maximumEncodedByteCount: 1, maximumPayloadByteCount: 1, maximumJSONTokens: value)
        }
    }

    @Test("Initial and intermediate invalid JSON never reaches the next migration", arguments: [false, true])
    func migrationPreflight(intermediate: Bool) throws {
        let valid = try payload()
        for duplicate in [false, true] {
            let invalid = duplicate ? Data("{\"secret\":0,\"\\u0073ecret\":1}".utf8) : Data("not JSON secret".utf8)
            let original = try envelope(intermediate ? valid : invalid)
            let before = original
            let calls = Mutex<[Int]>([])
            let codec = try RouterSnapshotCodec<R>(currentVersion: 3, migrations: [
                .init(from: 1, to: 2) { _ in calls.withLock { $0.append(1) }; return invalid },
                .init(from: 2, to: 3) { _ in calls.withLock { $0.append(2) }; return valid },
            ])
            let version = intermediate ? 2 : 1
            let expected: RouterSnapshotError = duplicate
                ? diagnostic(.duplicateJSONKey, stage: "payload", version: version)
                : .decodePayload(version: version, message: "Malformed JSON")
            #expect(throws: expected) { try codec.decode(original) }
            #expect(calls.withLock { $0 } == (intermediate ? [1] : []))
            #expect(original == before)
            #expect(!String(describing: expected).contains("secret"))
        }
    }

    @Test("Explicit recovery receives the precise preflight reason without changing source bytes")
    func recoveryAndSourcePreservation() throws {
        let original = try envelope(Data("{\"private-value\":0,\"private-value\":1}".utf8))
        let expected = diagnostic(.duplicateJSONKey, stage: "payload", version: 1)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try original.write(to: url)
        let data = try Data(contentsOf: url)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        #expect(throws: expected) { try codec.decode(data) }
        #expect(try Data(contentsOf: url) == original)
        let recovered = try codec.decode(data, recovery: .use { error in
            #expect(error == expected)
            return .rootStack(path: [.home])
        })
        #expect(recovered == .recovered(state: .rootStack(path: [.home]), reason: expected))
        #expect(try Data(contentsOf: url) == original)
        #expect(!String(describing: expected).contains("private-value"))
    }

    @Test("Malformed legacy error categories and application migration wrappers are preserved")
    func existingErrorContracts() throws {
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        #expect(throws: RouterSnapshotError.decodeEnvelope("Malformed JSON")) { try codec.decode(Data("?".utf8)) }
        let source = try envelope(payload())
        let expected = RouterSnapshotError.invalidSnapshotVersion(0)
        let migrating = try RouterSnapshotCodec<R>(currentVersion: 2, migrations: [
            .init(from: 1, to: 2) { _ in throw expected },
        ])
        #expect(throws: RouterSnapshotError.migrationFailed(from: 1, to: 2, message: String(describing: expected))) {
            try migrating.decode(source)
        }
    }

    @Test("Diagnostic codes and optional details remain extensible")
    func extensibleDiagnostic() throws {
        let error = RouterSnapshotPreflightError(code: .init(rawValue: "future.snapshot.code"))
        #expect(error.description == "future.snapshot.code")
        #expect(try JSONDecoder().decode(RouterSnapshotPreflightError.self, from: JSONEncoder().encode(error)) == error)
        #expect(error.details == .init())
    }
}
