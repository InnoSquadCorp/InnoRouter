import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

/// Synthetic contracts for newly implemented logical admission guards. These
/// tests do not establish elapsed-time, memory, or calibrated release budgets.
@Suite("Shared JSON cumulative work contracts")
struct RouterJSONWorkContractTests {
    private func validate(
        _ text: String,
        work: Int = Int.max,
        decodes: Int = Int.max,
        depth: Int = 1_024,
        required: [String: Int] = [:]
    ) throws -> RouterJSONWorkResult {
        let data = Data(text.utf8)
        return try RouterJSONPreflight.validate(
            data, maximumBytes: data.count, maximumDepth: depth, maximumTokens: data.count,
            byteName: "testBytes", requiredRootArrayLimits: required,
            workLimits: .init(maximumWorkUnits: work, maximumKeyDecodes: decodes)
        )
    }

    @Test("Empty input stays malformed and zero-key documents need no key decodes")
    func emptyAndScalarControls() throws {
        #expect(throws: RouterJSONPreflightError.malformedJSON) {
            try validate("", work: 0, decodes: 0)
        }
        #expect(throws: RouterJSONPreflightError.malformedJSON) {
            try validate(" \n\t ")
        }
        for text in ["null", "true", "false", "0", "-0.5e+2", #""hello""#, "[]", "{}"] {
            #expect(try validate(text, decodes: 0).keyDecodes == 0)
        }
        #expect(try validate("[]") == .init(workUnits: 9, keyDecodes: 0))
        #expect(try validate("{}") == .init(workUnits: 10, keyDecodes: 0))
    }

    @Test("Exact cumulative work passes and one more required unit rejects")
    func exactWorkBoundary() throws {
        // 3 * 7 byte passes, 5 tokens, 3 parser records, and 3 * 3 + 1 key work.
        #expect(try validate(#"{"a":0}"#, work: 39, decodes: 1) == .init(workUnits: 39, keyDecodes: 1))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 39, maximum: 38)) {
            try validate(#"{"a":0}"#, work: 38, decodes: 1)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 2, maximum: 1)) {
            try validate("[]", work: 1, decodes: 0)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 4, maximum: 3)) {
            try validate("[]", work: 3, decodes: 0)
        }
    }

    @Test("Key invocation caps are cumulative across siblings and root-array redecoding")
    func exactDecoderBoundary() throws {
        #expect(try validate(#"{"a":0,"b":0}"#, decodes: 2).keyDecodes == 2)
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 2, maximum: 1)) {
            try validate(#"{"a":0,"b":0}"#, decodes: 1)
        }
        #expect(try validate(#"[{"a":0},{"a":0}]"#, decodes: 2).keyDecodes == 2)
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 2, maximum: 1)) {
            try validate(#"[{"a":0},{"a":0}]"#, decodes: 1)
        }
        #expect(try validate(#"{"a":[]}"#, work: 57, decodes: 2, required: ["a": 0]) == .init(workUnits: 57, keyDecodes: 2))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 2, maximum: 1)) {
            try validate(#"{"a":[]}"#, decodes: 1, required: ["a": 0])
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 57, maximum: 56)) {
            try validate(#"{"a":[]}"#, work: 56, decodes: 2, required: ["a": 0])
        }
    }

    @Test("Escaped and Unicode keys retain existing duplicate semantics")
    func escapedAndUnicodeKeys() throws {
        for text in [
            #"{"a":0,"\u0061":1}"#,
            #"{"한":0,"\uD55C":1}"#,
            #"{"😀":0,"\uD83D\uDE00":1}"#,
            #"{"é":0,"e\u0301":1}"#,
        ] {
            #expect(throws: RouterJSONPreflightError.duplicateJSONKey) { try validate(text) }
        }
        for text in [
            #"{"a":0,"b":1}"#,
            #"{"한":0,"글":1}"#,
            #"{"\uD83D\uDE00":0,"\"\\\/\b\f\n\r\t":1}"#,
            #"[{"a":0},{"\u0061":1}]"#,
        ] {
            #expect(try validate(text).keyDecodes == 2)
        }
    }

    @Test("Malformed keys and invalid UTF-8 still fail closed")
    func malformedKeys() throws {
        for text in [
            #"{"\q":0}"#,
            #"{"\u12X4":0}"#,
            #"{"\uD800":0}"#,
            #"{"\uDC00":0}"#,
            #"{"\uD800\u0041":0}"#,
            "{\"tab\tkey\":0}",
            "{\"unfinished",
            #"{"a":0,}"#,
        ] {
            #expect(throws: RouterJSONPreflightError.malformedJSON) { try validate(text) }
        }
        for data in [
            Data([123, 34, 0xC0, 0xAF, 34, 58, 48, 125]), // overlong UTF-8
            Data([123, 34, 0xED, 0xA0, 0x80, 34, 58, 48, 125]), // encoded surrogate
            Data([123, 34, 0xF4, 0x90, 0x80, 0x80, 34, 58, 48, 125]), // beyond Unicode
        ] {
            #expect(throws: RouterJSONPreflightError.malformedJSON) {
                try RouterJSONPreflight.validate(
                    data, maximumBytes: 128, maximumDepth: 8, maximumTokens: 32, byteName: "testBytes"
                )
            }
        }
    }

    @Test("Escaped required root arrays retain count, presence, and type checks")
    func requiredRootArrays() throws {
        #expect(try validate(#"{"\u0073teps":[0,1]}"#, required: ["steps": 2]).keyDecodes == 2)
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "steps", actual: 2, maximum: 1)) {
            try validate(#"{"\u0073teps":[0,1]}"#, required: ["steps": 1])
        }
        for text in ["{}", #"{"steps":{}}"#, #"{"nested":{"steps":[]}}"#, "[]"] {
            #expect(throws: RouterJSONPreflightError.malformedJSON) {
                try validate(text, required: ["steps": 2])
            }
        }
        #expect(throws: RouterJSONPreflightError.duplicateJSONKey) {
            try validate(#"{"steps":[],"\u0073teps":[]}"#, required: ["steps": 0])
        }
    }

    @Test("Deep zero-key inputs are charged across every parser frame")
    func deepParserWork() throws {
        let depth = 256
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(try validate(text, work: depth * 9, decodes: 0, depth: depth) == .init(workUnits: depth * 9, keyDecodes: 0))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: depth * 9, maximum: depth * 9 - 1)) {
            try validate(text, work: depth * 9 - 1, decodes: 0, depth: depth)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonDepth", actual: depth, maximum: depth - 1)) {
            try validate(text, depth: depth - 1)
        }
    }

    @Test("Many empty or keyed siblings never reset cumulative work or invocations")
    func manySiblingWork() throws {
        let count = 512
        let empty = "[" + Array(repeating: "{}", count: count).joined(separator: ",") + "]"
        #expect(try validate(empty, work: 14 * count + 5, decodes: 0).workUnits == 14 * count + 5)
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 14 * count + 5, maximum: 14 * count + 4)) {
            try validate(empty, work: 14 * count + 4, decodes: 0)
        }
        let keyed = "[" + Array(repeating: #"{"a":0}"#, count: count).joined(separator: ",") + "]"
        #expect(try validate(keyed, work: 43 * count + 5, decodes: count) == .init(workUnits: 43 * count + 5, keyDecodes: count))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: count, maximum: count - 1)) {
            try validate(keyed, decodes: count - 1)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 43 * count + 5, maximum: 43 * count + 4)) {
            try validate(keyed, work: 43 * count + 4, decodes: count)
        }
    }

    @Test("Derived finite limits accept controls and safely saturate Int.max inputs")
    func derivedLimits() throws {
        #expect(RouterJSONWorkLimits.derived(maximumBytes: 7, maximumTokens: 5) == .init(maximumWorkUnits: 105, maximumKeyDecodes: 5))
        #expect(RouterJSONWorkLimits.derived(maximumBytes: Int.max, maximumTokens: Int.max) == .init(maximumWorkUnits: Int.max, maximumKeyDecodes: Int.max))
        #expect(RouterJSONWorkLimits.derived(maximumBytes: Int.max / 10, maximumTokens: Int.max / 7).maximumWorkUnits == Int.max)
        #expect(RouterJSONWorkLimits.derived(maximumBytes: -1, maximumTokens: -1) == .init(maximumWorkUnits: 0, maximumKeyDecodes: 0))
        for text in ["[]", "{}", #"{"a":0}"#, #"{"items":[{"a":1},{"b":2}]}"#] {
            let data = Data(text.utf8)
            let result = try RouterJSONPreflight.validate(
                data, maximumBytes: data.count, maximumDepth: 8, maximumTokens: data.count, byteName: "testBytes"
            )
            let limits = RouterJSONWorkLimits.derived(maximumBytes: data.count, maximumTokens: data.count)
            #expect(result.workUnits <= limits.maximumWorkUnits)
            #expect(result.keyDecodes <= limits.maximumKeyDecodes)
        }
        #expect(try RouterJSONPreflight.validate(
            Data("[]".utf8), maximumBytes: Int.max, maximumDepth: Int.max,
            maximumTokens: Int.max, byteName: "testBytes"
        ) == .init(workUnits: 9, keyDecodes: 0))
    }

    @Test("Overflow and exhausted reservations fail before isolated decoder entry")
    func overflowSafeReservation() throws {
        var calls = 0
        var budget = RouterJSONWorkBudget(limits: .init(maximumWorkUnits: Int.max, maximumKeyDecodes: Int.max))
        try budget.charge(Int.max)
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: Int.max, maximum: Int.max)) {
            try budget.charge(1)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: Int.max, maximum: Int.max)) {
            try budget.withKeyDecode(byteCount: 0) { calls += 1 }
        }
        #expect(budget.result == .init(workUnits: Int.max, keyDecodes: 0))
        var fresh = RouterJSONWorkBudget(limits: .init(maximumWorkUnits: Int.max, maximumKeyDecodes: Int.max))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: Int.max, maximum: Int.max)) {
            try fresh.withKeyDecode(byteCount: Int.max) { calls += 1 }
        }
        #expect(fresh.result == .init(workUnits: 0, keyDecodes: 0))
        var full = try RouterJSONWorkBudget(
            limits: .init(maximumWorkUnits: Int.max, maximumKeyDecodes: Int.max),
            consumed: .init(workUnits: 0, keyDecodes: Int.max)
        )
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: Int.max, maximum: Int.max)) {
            try full.withKeyDecode(byteCount: 0) { calls += 1 }
        }
        #expect(full.result == .init(workUnits: 0, keyDecodes: Int.max))
        #expect(calls == 0)
    }

    @Test("A continued phase shares both counters and reserves before its closure")
    func continuedBudget() throws {
        let first = try validate(#"{"a":0}"#)
        var calls = 0
        var budget = try RouterJSONWorkBudget(
            limits: .init(maximumWorkUnits: 49, maximumKeyDecodes: 2), consumed: first
        )
        try budget.withKeyDecode(byteCount: 3) { calls += 1 }
        #expect(budget.result == .init(workUnits: 49, keyDecodes: 2))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 3, maximum: 2)) {
            try budget.withKeyDecode(byteCount: 3) { calls += 1 }
        }
        #expect(calls == 1)
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: 39, maximum: 38)) {
            try RouterJSONWorkBudget(limits: .init(maximumWorkUnits: 38, maximumKeyDecodes: 2), consumed: first)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 1, maximum: 0)) {
            try RouterJSONWorkBudget(limits: .init(maximumWorkUnits: 49, maximumKeyDecodes: 0), consumed: first)
        }
    }

    private final class DecodeCalls: Sendable {
        private let storage = Mutex(0)
        var count: Int { storage.withLock { $0 } }
        func hit() { storage.withLock { $0 += 1 } }
    }

    private struct RouteProbe: Decodable {
        static let callsKey = CodingUserInfoKey(rawValue: "JSONWorkRouteProbe.calls")!
        let value: Int

        init(from decoder: any Decoder) throws {
            (decoder.userInfo[Self.callsKey] as? DecodeCalls)?.hit()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Int.self, forKey: .value)
        }

        private enum CodingKeys: String, CodingKey { case value }
    }

    @Test("Composition rejects work and invocation excess before application Decodable")
    func noRouteDecoderAfterRejection() throws {
        let text = #"{"value":1}"#
        let data = Data(text.utf8)
        let usage = try validate(text)
        let calls = DecodeCalls()
        func decode(work: Int, decodes: Int) throws -> RouteProbe {
            try RouterJSONPreflight.validate(
                data, maximumBytes: data.count, maximumDepth: 4, maximumTokens: data.count,
                byteName: "testBytes", workLimits: .init(maximumWorkUnits: work, maximumKeyDecodes: decodes)
            )
            let decoder = JSONDecoder()
            decoder.userInfo[RouteProbe.callsKey] = calls
            return try decoder.decode(RouteProbe.self, from: data)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonWorkUnits", actual: usage.workUnits, maximum: usage.workUnits - 1)) {
            try decode(work: usage.workUnits - 1, decodes: 1)
        }
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: 1, maximum: 0)) {
            try decode(work: usage.workUnits, decodes: 0)
        }
        #expect(calls.count == 0)
        #expect(try decode(work: usage.workUnits, decodes: 1).value == 1)
        #expect(calls.count == 1)
    }
}
