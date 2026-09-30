import Foundation

/// Scans only envelope structure before decoding potentially large entry trees.
/// Escaped keys are recognized and duplicate envelope members fail closed.
enum RouterInspectorImportPreflight {
    static func validate(
        _ data: Data,
        limits: RouterInspectorImportLimits,
        diagnosticBundle: Bool = false
    ) throws {
        try validateByteCount(data, limits: limits)
        let bytes = Array(data)
        let snapshotStart: Int
        if diagnosticBundle {
            _ = try requiredMember("formatVersion", in: bytes, startingAt: 0)
            snapshotStart = try requiredMember("snapshot", in: bytes, startingAt: 0)
        } else {
            snapshotStart = 0
        }
        let entriesStart = try requiredMember("entries", in: bytes, startingAt: snapshotStart)
        let count = try countArrayElements(in: bytes, startingAt: entriesStart)
        guard count <= limits.maximumEntryCount else {
            throw RouterInspectorImportError.tooManyEntries(
                actualCount: count,
                maximumCount: limits.maximumEntryCount
            )
        }
    }

    /// Shared by the native file importer so a bundle never falls back to an
    /// unversioned snapshot after a version or validation failure.
    static func isDiagnosticBundle(_ data: Data, limits: RouterInspectorImportLimits) throws -> Bool {
        try validateByteCount(data, limits: limits)
        return try member("formatVersion", in: Array(data), startingAt: 0) != nil
    }

    private static func validateByteCount(_ data: Data, limits: RouterInspectorImportLimits) throws {
        guard data.count <= limits.maximumEncodedByteCount else {
            throw RouterInspectorImportError.encodedDataTooLarge(
                actualByteCount: data.count,
                maximumByteCount: limits.maximumEncodedByteCount
            )
        }
    }

    private static func requiredMember(_ key: String, in bytes: [UInt8], startingAt start: Int) throws -> Int {
        guard let index = try member(key, in: bytes, startingAt: start) else {
            throw RouterInspectorImportError.malformedSnapshotEnvelope
        }
        return index
    }

    private static func member(_ key: String, in bytes: [UInt8], startingAt start: Int) throws -> Int? {
        var index = start
        skipWhitespace(in: bytes, index: &index)
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
                    skipWhitespace(in: bytes, index: &valueStart)
                    if valueStart < bytes.count, bytes[valueStart] == 0x3A,
                       try matchesKey(key, bytes: bytes, range: stringStart...index) {
                        guard result == nil else {
                            throw RouterInspectorImportError.malformedSnapshotEnvelope
                        }
                        valueStart += 1
                        skipWhitespace(in: bytes, index: &valueStart)
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

    private static func matchesKey(_ key: String, bytes: [UInt8], range: ClosedRange<Int>) throws -> Bool {
        let contents = bytes[(range.lowerBound + 1)..<range.upperBound]
        if !contents.contains(0x5C) {
            return contents.elementsEqual(key.utf8)
        }
        return try JSONDecoder().decode(String.self, from: Data(bytes[range])) == key
    }

    private static func countArrayElements(in bytes: [UInt8], startingAt start: Int) throws -> Int {
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

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, isWhitespace(bytes[index]) {
            index += 1
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
