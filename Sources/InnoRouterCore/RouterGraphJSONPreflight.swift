import Foundation

/// Iterative syntax/complexity screening before a Foundation graph decode.
/// Only after the complete document passes the byte/depth/token checks do we
/// decode isolated string keys, to reject duplicates even with escaped spelling.
enum RouterGraphJSONPreflight {
    private struct Frame {
        var kind: UInt8
        var state = 0
        var keys: [Range<Int>] = []
    }

    static func validate(_ data: Data, maximumBytes: Int, limits: RouterGraphSnapshotLimits, byteName: String) throws {
        try check(data.count, maximum: maximumBytes, name: byteName)
        var parser = Parser(bytes: Array(data), limits: limits)
        try parser.run()
        guard String(data: data, encoding: .utf8) != nil else { throw RouterGraphSnapshotError.malformedJSON }
        // Only bounded scalar strings are decoded, after the whole document's
        // byte/depth/token checks have passed. Escaped aliases are duplicates.
        let decoder = JSONDecoder()
        for group in parser.keyGroups {
            var keys: Set<String> = []
            for range in group {
                guard let key = try? decoder.decode(String.self, from: Data(parser.bytes[range])) else {
                    throw RouterGraphSnapshotError.malformedJSON
                }
                guard keys.insert(key).inserted else { throw RouterGraphSnapshotError.duplicateJSONKey }
            }
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        let limits: RouterGraphSnapshotLimits
        var index = 0
        var tokens = 0
        var frames: [Frame] = []
        var keyGroups: [[Range<Int>]] = []
        var rootConsumed = false

        mutating func run() throws {
            while index < bytes.count {
                if isWhitespace(bytes[index]) {
                    index += 1
                    continue
                }
                tokens += 1
                try check(tokens, maximum: limits.maximumJSONTokens, name: "jsonTokens")
                let start = index
                let token = try nextToken()
                if !frames.isEmpty {
                    let handled = frames[frames.count - 1].kind == 123
                        ? try consumeObject(token, range: start..<index)
                        : try consumeArray(token)
                    if handled { continue }
                } else if rootConsumed {
                    throw RouterGraphSnapshotError.malformedJSON
                }
                try consumeValue(token)
            }
            guard rootConsumed, frames.isEmpty else { throw RouterGraphSnapshotError.malformedJSON }
        }

        mutating func nextToken() throws -> UInt8 {
            let token = bytes[index]
            switch token {
            case 34: try scanString(bytes, index: &index)
            case 91, 93, 123, 125, 58, 44: index += 1
            case 116: try scanLiteral([116, 114, 117, 101], bytes, index: &index)
            case 102: try scanLiteral([102, 97, 108, 115, 101], bytes, index: &index)
            case 110: try scanLiteral([110, 117, 108, 108], bytes, index: &index)
            case 45, 48...57: try scanNumber(bytes, index: &index)
            default: throw RouterGraphSnapshotError.malformedJSON
            }
            return token
        }

        mutating func consumeObject(_ token: UInt8, range: Range<Int>) throws -> Bool {
            let position = frames.count - 1
            let state = frames[position].state
            switch state {
            case 0, 4:
                if token == 125 && state == 0 {
                    keyGroups.append(frames.removeLast().keys)
                    return true
                }
                guard token == 34 else { throw RouterGraphSnapshotError.malformedJSON }
                frames[position].keys.append(range)
                frames[position].state = 1
            case 1:
                guard token == 58 else { throw RouterGraphSnapshotError.malformedJSON }
                frames[position].state = 2
            case 3:
                if token == 125 { keyGroups.append(frames.removeLast().keys) }
                else if token == 44 { frames[position].state = 4 }
                else { throw RouterGraphSnapshotError.malformedJSON }
            default: return false
            }
            return true
        }

        mutating func consumeArray(_ token: UInt8) throws -> Bool {
            let position = frames.count - 1
            if frames[position].state == 1 {
                if token == 93 { frames.removeLast() }
                else if token == 44 { frames[position].state = 2 }
                else { throw RouterGraphSnapshotError.malformedJSON }
                return true
            }
            if token == 93 && frames[position].state == 0 {
                frames.removeLast()
                return true
            }
            return false
        }

        mutating func consumeValue(_ token: UInt8) throws {
            guard token != 93, token != 125, token != 58, token != 44 else {
                throw RouterGraphSnapshotError.malformedJSON
            }
            if frames.isEmpty { rootConsumed = true }
            else {
                let position = frames.count - 1
                frames[position].state = frames[position].kind == 123 ? 3 : 1
            }
            if token == 123 || token == 91 {
                try check(frames.count + 1, maximum: limits.maximumJSONDepth, name: "jsonDepth")
                frames.append(Frame(kind: token))
            }
        }
    }

    static func check(_ actual: Int, maximum: Int, name: String) throws {
        guard actual <= maximum else {
            throw RouterGraphSnapshotError.limitExceeded(name: name, actual: actual, maximum: maximum)
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func scanString(_ bytes: [UInt8], index: inout Int) throws {
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 { return }
            guard byte >= 32 else { throw RouterGraphSnapshotError.malformedJSON }
            if byte == 92 {
                guard index < bytes.count else { throw RouterGraphSnapshotError.malformedJSON }
                let escaped = bytes[index]
                index += 1
                if escaped == 117 {
                    guard bytes.count - index >= 4 else { throw RouterGraphSnapshotError.malformedJSON }
                    for _ in 0..<4 {
                        let hex = bytes[index]
                        guard (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else {
                            throw RouterGraphSnapshotError.malformedJSON
                        }
                        index += 1
                    }
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) {
                    throw RouterGraphSnapshotError.malformedJSON
                }
            }
        }
        throw RouterGraphSnapshotError.malformedJSON
    }

    private static func scanLiteral(_ literal: [UInt8], _ bytes: [UInt8], index: inout Int) throws {
        guard bytes.count - index >= literal.count,
              bytes[index..<(index + literal.count)].elementsEqual(literal) else {
            throw RouterGraphSnapshotError.malformedJSON
        }
        index += literal.count
    }

    private static func scanNumber(_ bytes: [UInt8], index: inout Int) throws {
        if bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw RouterGraphSnapshotError.malformedJSON }
        if bytes[index] == 48 { index += 1 }
        else {
            guard (49...57).contains(bytes[index]) else { throw RouterGraphSnapshotError.malformedJSON }
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard index > start else { throw RouterGraphSnapshotError.malformedJSON }
        }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            let start = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard index > start else { throw RouterGraphSnapshotError.malformedJSON }
        }
    }
}
