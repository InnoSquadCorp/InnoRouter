import Foundation
import InnoRouterCore

/// Scans only envelope structure before decoding potentially large entry trees.
/// Escaped keys are recognized and duplicate envelope members fail closed.
enum RouterInspectorImportPreflight {
    static func validate(
        _ data: Data,
        limits: RouterInspectorImportLimits,
        diagnosticBundle: Bool = false
    ) throws {
        try withJSONBudget(data, limits: limits) { bytes, work in
            try validateContents(bytes, limits: limits, diagnosticBundle: diagnosticBundle, work: &work)
            try work.charge(data.count)
        }
    }

    /// One UI import admission across format detection, content checks and the
    /// final typed decoder. The classification phase cannot reset its ledger.
    static func classifyAndValidate(_ data: Data, limits: RouterInspectorImportLimits) throws -> Bool {
        try withJSONBudget(data, limits: limits) { bytes, work in
            let diagnostic = try member("formatVersion", in: bytes, startingAt: 0, work: &work) != nil
            try validateContents(bytes, limits: limits, diagnosticBundle: diagnostic, work: &work)
            try work.charge(data.count)
            return diagnostic
        }
    }

    private static func validateContents(
        _ bytes: [UInt8], limits: RouterInspectorImportLimits,
        diagnosticBundle: Bool, work: inout RouterJSONWorkBudget
    ) throws {
        let snapshotStart: Int
        if diagnosticBundle {
            _ = try requiredMember("formatVersion", in: bytes, startingAt: 0, work: &work)
            snapshotStart = try requiredMember("snapshot", in: bytes, startingAt: 0, work: &work)
        } else { snapshotStart = 0 }
        let entriesStart = try requiredMember("entries", in: bytes, startingAt: snapshotStart, work: &work)
        let count = try countArrayElements(in: bytes, startingAt: entriesStart, work: &work)
        guard count <= limits.maximumEntryCount else {
            throw RouterInspectorImportError.tooManyEntries(actualCount: count, maximumCount: limits.maximumEntryCount)
        }
    }

    /// Classification also guards its extra escaped-key decoder; a malformed
    /// graph/bundle marker cannot force a second format through fallback.
    static func isDiagnosticBundle(_ data: Data, limits: RouterInspectorImportLimits) throws -> Bool {
        try withJSONBudget(data, limits: limits) { bytes, work in
            try member("formatVersion", in: bytes, startingAt: 0, work: &work) != nil
        }
    }

    private static func withJSONBudget<Value>(
        _ data: Data, limits: RouterInspectorImportLimits,
        operation: ([UInt8], inout RouterJSONWorkBudget) throws -> Value
    ) throws -> Value {
        try validateByteCount(data, limits: limits)
        do {
            let derived = RouterJSONWorkLimits.derived(maximumBytes: limits.maximumEncodedByteCount, maximumTokens: limits.maximumJSONTokens)
            let workLimits = RouterJSONWorkLimits(
                maximumWorkUnits: limits.maximumJSONWorkUnits ?? derived.maximumWorkUnits,
                maximumKeyDecodes: limits.maximumJSONKeyDecodes ?? derived.maximumKeyDecodes
            )
            let used = try RouterJSONPreflight.validate(
                data, maximumBytes: limits.maximumEncodedByteCount,
                maximumDepth: limits.maximumJSONDepth,
                maximumTokens: limits.maximumJSONTokens, byteName: "encodedBytes",
                workLimits: workLimits
            )
            var work = try RouterJSONWorkBudget(limits: workLimits, consumed: used)
            try work.charge(data.count)
            return try operation(Array(data), &work)
        } catch let error as RouterJSONPreflightError {
            switch error {
            case .limitExceeded("jsonDepth", let actual, let maximum):
                throw RouterInspectorImportError.jsonDepthExceeded(actualDepth: actual, maximumDepth: maximum)
            case .limitExceeded("jsonTokens", let actual, let maximum):
                throw RouterInspectorImportError.jsonTokenLimitExceeded(actualCount: actual, maximumCount: maximum)
            case .limitExceeded(let field, let actual, let maximum) where field == "jsonWorkUnits" || field == "jsonKeyDecodes":
                throw RouterInspectorImportError.resourceLimit(.init(resource: field, actual: actual, maximum: maximum))
            case .malformedJSON, .duplicateJSONKey, .limitExceeded:
                throw RouterInspectorImportError.malformedSnapshotEnvelope
            }
        }
    }

    private static func validateByteCount(_ data: Data, limits: RouterInspectorImportLimits) throws {
        guard data.count <= limits.maximumEncodedByteCount else {
            throw RouterInspectorImportError.encodedDataTooLarge(
                actualByteCount: data.count,
                maximumByteCount: limits.maximumEncodedByteCount
            )
        }
    }

    private static func requiredMember(_ key: String, in bytes: [UInt8], startingAt start: Int, work: inout RouterJSONWorkBudget) throws -> Int {
        guard let index = try member(key, in: bytes, startingAt: start, work: &work) else {
            throw RouterInspectorImportError.malformedSnapshotEnvelope
        }
        return index
    }

    private static func member(_ key: String, in bytes: [UInt8], startingAt start: Int, work: inout RouterJSONWorkBudget) throws -> Int? {
        guard start >= 0, start <= bytes.count else { throw RouterInspectorImportError.malformedSnapshotEnvelope }
        try work.charge(bytes.count - start)
        var index = start
        try skipWhitespace(in: bytes, index: &index, work: &work)
        guard index < bytes.count, bytes[index] == 0x7B else {
            throw RouterInspectorImportError.malformedSnapshotEnvelope
        }
        var objectDepth = 0
        var arrayDepth = 0
        var result: Int?
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                let stringStart = index
                index = try endOfString(in: bytes, startingAt: index)
                if objectDepth == 1, arrayDepth == 0 {
                    var valueStart = index + 1
                    try skipWhitespace(in: bytes, index: &valueStart, work: &work)
                    if valueStart < bytes.count, bytes[valueStart] == 0x3A,
                       try matchesKey(key, bytes: bytes, range: stringStart...index, work: &work) {
                        guard result == nil else {
                            throw RouterInspectorImportError.malformedSnapshotEnvelope
                        }
                        valueStart += 1
                        try skipWhitespace(in: bytes, index: &valueStart, work: &work)
                        result = valueStart
                    }
                }
            case 0x7B:
                objectDepth += 1
            case 0x7D:
                objectDepth -= 1
                if objectDepth == 0 {
                    guard arrayDepth == 0 else {
                        throw RouterInspectorImportError.malformedSnapshotEnvelope
                    }
                    return result
                }
            case 0x5B:
                arrayDepth += 1
            case 0x5D:
                arrayDepth -= 1
                guard arrayDepth >= 0 else {
                    throw RouterInspectorImportError.malformedSnapshotEnvelope
                }
            default:
                break
            }
            index += 1
        }
        throw RouterInspectorImportError.malformedSnapshotEnvelope
    }

    private static func matchesKey(_ key: String, bytes: [UInt8], range: ClosedRange<Int>, work: inout RouterJSONWorkBudget) throws -> Bool {
        try work.charge(range.count)
        try work.charge(range.count)
        let contents = bytes[(range.lowerBound + 1)..<range.upperBound]
        if !contents.contains(0x5C) {
            return contents.elementsEqual(key.utf8)
        }
        return try work.withKeyDecode(byteCount: range.count) {
            try JSONDecoder().decode(String.self, from: Data(bytes[range])) == key
        }
    }

    private static func countArrayElements(in bytes: [UInt8], startingAt start: Int, work: inout RouterJSONWorkBudget) throws -> Int {
        guard start >= 0, start <= bytes.count else { throw RouterInspectorImportError.malformedSnapshotEnvelope }
        try work.charge(bytes.count - start)
        guard start < bytes.count, bytes[start] == 0x5B else {
            throw RouterInspectorImportError.malformedSnapshotEnvelope
        }
        var index = start + 1
        var nestedDepth = 0
        var count = 0
        var expectsValue = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                if nestedDepth == 0, expectsValue {
                    count += 1
                    expectsValue = false
                }
                index = try endOfString(in: bytes, startingAt: index) + 1
                continue
            }
            if byte == 0x7B || byte == 0x5B {
                if nestedDepth == 0, expectsValue {
                    count += 1
                    expectsValue = false
                }
                nestedDepth += 1
            } else if byte == 0x7D || byte == 0x5D {
                if nestedDepth == 0 {
                    guard byte == 0x5D, !expectsValue || count == 0 else {
                        throw RouterInspectorImportError.malformedSnapshotEnvelope
                    }
                    return count
                }
                nestedDepth -= 1
            } else if nestedDepth == 0, byte == 0x2C {
                guard !expectsValue else {
                    throw RouterInspectorImportError.malformedSnapshotEnvelope
                }
                expectsValue = true
            } else if nestedDepth == 0, expectsValue, !isWhitespace(byte) {
                count += 1
                expectsValue = false
            }
            index += 1
        }
        throw RouterInspectorImportError.malformedSnapshotEnvelope
    }

    private static func endOfString(in bytes: [UInt8], startingAt start: Int) throws -> Int {
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return index
            }
            index += 1
        }
        throw RouterInspectorImportError.malformedSnapshotEnvelope
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int, work: inout RouterJSONWorkBudget) throws {
        while index < bytes.count, isWhitespace(bytes[index]) {
            try work.charge(1)
            index += 1
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
