import Foundation
import Synchronization
import Testing

import InnoRouter
import InnoRouterTesting

private enum ImportBoundRoute: String, Route, Codable {
    case home
    static let decodeCalls = Mutex(0)

    init(from decoder: any Decoder) throws {
        Self.decodeCalls.withLock { $0 += 1 }
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let route = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown route"))
        }
        self = route
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

@Suite("Scenario pre-decoding limits", .serialized)
struct RouterScenarioImportLimitTests {
    @Test("Valid bytes at the limit decode; limit plus one preserves input without decoding routes")
    func byteBoundary() throws {
        let data = try fixtureData()
        resetCalls()
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumByteCount: data.count).steps.count == 1)
        #expect(calls > 0)
        let larger = data + Data([32])
        try rejectsWithoutRoutes(larger, .encodedDataTooLarge(actual: larger.count, maximum: data.count)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: larger, maximumByteCount: data.count)
        }
    }

    @Test("Step cardinality is checked before initial-state or step route decoding")
    func stepBoundaryBeforeRouteDecoding() throws {
        let valid = try fixtureData(steps: 2)
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(from: valid, maximumStepCount: 2).steps.count == 2)
        let excess = try fixtureData(steps: 3)
        try rejectsWithoutRoutes(excess, .tooManySteps(actual: 3, maximum: 2)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: excess, maximumStepCount: 2)
        }
    }

    @Test("Escaped steps keys use the same envelope cardinality contract")
    func escapedRootArrayKey() throws {
        let valid = replacingStepsKey(try fixtureData(), with: #"st\u0065ps"#)
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(from: valid, maximumStepCount: 1).steps.count == 1)
        let excess = replacingStepsKey(try fixtureData(steps: 2), with: #"st\u0065ps"#)
        try rejectsWithoutRoutes(excess, .tooManySteps(actual: 2, maximum: 1)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: excess, maximumStepCount: 1)
        }
    }

    @Test("Nested same-name arrays are not mistaken for the top-level steps envelope")
    func nestedStepsControl() throws {
        let data = try addingUnknown(#"{"steps":[0,1,2,3],"escaped":{"st\u0065ps":[4,5]}}"#)
        resetCalls()
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumStepCount: 1).steps.count == 1)
        #expect(calls > 0)
    }

    @Test("Depth limit accepts the boundary and rejects one deeper even in unknown fields")
    func depthBoundary() throws {
        let data = try addingUnknown(String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32))
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumJSONDepth: 33).steps.count == 1)
        try rejectsWithoutRoutes(data, .jsonDepthExceeded(actual: 33, maximum: 32)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumJSONDepth: 32)
        }
    }

    @Test("Default depth limit blocks unknown deeply nested payload before route decoding")
    func defaultDepthLimit() throws {
        let data = try addingUnknown(String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64))
        try rejectsWithoutRoutes(data, .jsonDepthExceeded(actual: 65, maximum: 64)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data)
        }
    }

    @Test("Token limits include punctuation and unknown values at exact boundaries")
    func tokenBoundary() throws {
        let data = try addingUnknown(#"{"words":["comma,braces{}","escaped\"quote",null,true,1.25]}"#)
        let tokens = try tokenCount(data)
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumJSONTokens: tokens).steps.count == 1)
        try rejectsWithoutRoutes(data, .jsonTokenLimitExceeded(actual: tokens, maximum: tokens - 1)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumJSONTokens: tokens - 1)
        }
    }

    @Test("Default token limit rejects a small but token-dense unknown array")
    func defaultTokenLimit() throws {
        let data = try addingUnknown("[" + Array(repeating: "0", count: 70_000).joined(separator: ",") + "]")
        #expect(data.count < 2 * 1_024 * 1_024)
        try rejectsWithoutRoutes(data, .jsonTokenLimitExceeded(actual: 131_073, maximum: 131_072)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data)
        }
    }

    @Test("Duplicate root, escaped-alias and unknown nested keys fail closed", arguments: [
        #""steps":[]"#,
        #""st\u0065ps":[]"#,
        #""unknown":{"private-payload":1,"private-payload":2}"#,
    ])
    func duplicateKeys(member: String) throws {
        let data = try addingMember(member)
        try rejectsWithoutRoutes(data, .malformedFixtureEnvelope) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data)
        }
    }

    @Test("Missing or non-array steps envelopes reject before application decoding", arguments: ["missing", "object", "null"])
    func malformedStepEnvelope(kind: String) throws {
        let original = try fixtureData()
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        switch kind {
        case "missing": object.removeValue(forKey: "steps")
        case "object": object["steps"] = ["steps": []]
        default: object["steps"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try rejectsWithoutRoutes(data, .malformedFixtureEnvelope) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data)
        }
    }

    @Test("Malformed, truncated and invalid-UTF8 documents never reach a route decoder")
    func malformedJSON() throws {
        let data = try fixtureData()
        for invalid in [Data(data.dropLast()), data + Data("null".utf8), try addingMember("\"unknown\":\"" + String(UnicodeScalar(0)!) + "\"") ] {
            try rejectsWithoutRoutes(invalid, .malformedFixtureEnvelope) {
                _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: invalid)
            }
        }
        let invalidUTF8 = data.dropLast() + Data([44, 34, 120, 34, 58, 34, 255, 34, 125])
        try rejectsWithoutRoutes(Data(invalidUTF8), .malformedFixtureEnvelope) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: Data(invalidUTF8))
        }
    }

    @Test("Nonpositive limits normalize to one and Int.max overrides do not overflow")
    func normalizedAndLargeLimits() throws {
        let data = try fixtureData()
        #expect(try RouterScenarioFixture<ImportBoundRoute>.decode(
            from: data, maximumByteCount: Int.max, maximumStepCount: 0,
            maximumJSONDepth: Int.max, maximumJSONTokens: Int.max
        ).steps.count == 1)
        try rejectsWithoutRoutes(data, .encodedDataTooLarge(actual: data.count, maximum: 1)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumByteCount: -1)
        }
        try rejectsWithoutRoutes(data, .jsonDepthExceeded(actual: 2, maximum: 1)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumJSONDepth: 0)
        }
        try rejectsWithoutRoutes(data, .jsonTokenLimitExceeded(actual: 2, maximum: 1)) {
            _ = try RouterScenarioFixture<ImportBoundRoute>.decode(from: data, maximumJSONTokens: -1)
        }
    }

    private var calls: Int { ImportBoundRoute.decodeCalls.withLock { $0 } }
    private func resetCalls() { ImportBoundRoute.decodeCalls.withLock { $0 = 0 } }

    private func fixtureData(steps count: Int = 1) throws -> Data {
        let state = RouterState<ImportBoundRoute>.rootStack(path: [.home])
        let fixture = RouterScenarioFixture(initialState: state, steps: (0..<count).map { index in
            RouterScenarioStep(
                submissionIndex: index, submissionEventIndex: index * 2, terminalEventIndex: index * 2 + 1,
                action: RouterAction<ImportBoundRoute>.push(.home), context: .init(),
                observedState: state, observedRevision: 0, observedTerminal: .unchanged
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fixture)
    }

    private func addingUnknown(_ value: String) throws -> Data {
        try addingMember("\"unknown\":" + value)
    }

    private func addingMember(_ member: String) throws -> Data {
        let data = try fixtureData()
        return Data(data.dropLast()) + Data(("," + member + "}").utf8)
    }

    private func replacingStepsKey(_ data: Data, with key: String) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"steps\":", with: "\"" + key + "\":").utf8)
    }

    private func tokenCount(_ data: Data) throws -> Int {
        let text = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|[\[\]{}:,]"#)
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func rejectsWithoutRoutes(
        _ data: Data,
        _ error: RouterScenarioFixtureError,
        operation: () throws -> Void
    ) throws {
        let original = data
        resetCalls()
        #expect(throws: error) { try operation() }
        #expect(calls == 0)
        #expect(data == original)
    }
}
