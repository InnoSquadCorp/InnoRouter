import Foundation
import Synchronization

/// Decoder-local route admission using exact JSON value spans. It never calls
/// an app's Decodable or re-encodes/normalizes its payload to estimate byte size.
package final class RouterLegacyRouteAdmission: Sendable {
    package static let key = CodingUserInfoKey(rawValue: "InnoRouter.legacy.routeAdmission")!
    private struct Ledger: Sendable {
        var work: RouterJSONWorkBudget
        var routeCount = 0
        var routeBytes = 0
    }
    private let ledger: Mutex<Ledger>
    package var work: RouterJSONWorkBudget { ledger.withLock { $0.work } }
    private let limits: RouterGraphSnapshotLimits
    private let spans: RouterJSONValueSpans

    /// The caller must have completed shared JSON syntax/depth/token preflight.
    package init(validatedJSON data: Data, limits: RouterGraphSnapshotLimits, work: RouterJSONWorkBudget) throws {
        var admitted = work
        let spans = try RouterJSONValueSpans(validatedJSON: data, work: &admitted)
        self.ledger = Mutex(Ledger(work: admitted))
        self.limits = limits
        self.spans = spans
    }

    /// An inert marker pass over library-owned slots, including historical
    /// migration documents. Malformed unrelated structure cannot end traversal
    /// before a later known slot. Route payloads are never inspected.
    package static func rejectTransientMarkers(in data: Data, stateKey: String? = nil, work: inout RouterJSONWorkBudget?) throws {
        var admitted = work ?? .init(limits: .init(maximumWorkUnits: .max, maximumKeyDecodes: .max))
        let spans = try RouterJSONValueSpans(validatedJSON: data, work: &admitted, permitsDuplicateKeys: work == nil)
        try spans.rejectTransientState(stateKey: stateKey, work: &admitted)
        if work != nil { work = admitted }
    }

    package func admit(path: [any CodingKey]) throws {
        try ledger.withLock { state in
            try state.work.charge(1)
            let range = try spans.range(at: path, work: &state.work)
            state.routeCount = try adding(state.routeCount, 1, maximum: limits.maximumRoutes, name: "routes")
            _ = try adding(0, range.count, maximum: limits.maximumRoutePayloadBytes, name: "routePayloadBytes")
            state.routeBytes = try adding(state.routeBytes, range.count, maximum: limits.maximumPayloadBytes, name: "totalRoutePayloadBytes")
        }
    }

    private func adding(_ value: Int, _ count: Int, maximum: Int, name: String) throws -> Int {
        let (next, overflow) = value.addingReportingOverflow(count)
        guard count >= 0, !overflow, next <= maximum else {
            throw RouterJSONPreflightError.limitExceeded(name: name, actual: overflow ? .max : next, maximum: maximum)
        }
        return next
    }
}

/// The opaque shape carries no application payload. Coding paths select exact
/// original spans, including escapes and internal whitespace, before app decode.
package struct RouterLegacyRouteShape: Route, Codable {
    package init(from decoder: any Decoder) throws {
        guard let admission = decoder.userInfo[RouterLegacyRouteAdmission.key] as? RouterLegacyRouteAdmission else {
            throw RouterJSONPreflightError.malformedJSON
        }
        try admission.admit(path: decoder.codingPath)
    }
}

/// A flat, iterative index over already validated bytes. The index retains only
/// ranges/container links, not decoded route values or recursive JSON objects.
private struct RouterJSONValueSpans: Sendable {
    private struct Entry: Sendable {
        var range: Range<Int>
        var members: [String: Int]?
        var elements: [Int]?
    }
    private struct Frame {
        let id: Int
        let object: Bool
        var expectsKey: Bool
        var key: String?
    }
    private let entries: [Entry]
    private let duplicateMembers: [Int: [String: [Int]]]

    init(validatedJSON data: Data, work: inout RouterJSONWorkBudget, permitsDuplicateKeys: Bool = false) throws {
        try work.charge(data.count)
        let bytes = Array(data)
        var entries: [Entry] = []
        var duplicateMembers: [Int: [String: [Int]]] = [:]
        var frames: [Frame] = []
        let decoder = JSONDecoder()
        var cursor = 0
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if Self.whitespace(byte) { try work.charge(1); cursor += 1; continue }
            if byte == 44 || byte == 58 {
                try work.charge(1)
                if byte == 44, let last = frames.indices.last, frames[last].object { frames[last].expectsKey = true }
                cursor += 1
                continue
            }
            if byte == 125 || byte == 93 {
                try work.charge(1)
                guard let frame = frames.popLast(), frame.object == (byte == 125) else {
                    throw RouterJSONPreflightError.malformedJSON
                }
                cursor += 1
                entries[frame.id].range = entries[frame.id].range.lowerBound..<cursor
                continue
            }
            let start = cursor
            let compound = byte == 123 || byte == 91
            if compound { try work.charge(1); cursor += 1 }
            else { try Self.advanceScalar(bytes, cursor: &cursor, work: &work) }
            let range = start..<cursor
            if let last = frames.indices.last, frames[last].object, frames[last].expectsKey {
                guard byte == 34, !compound else { throw RouterJSONPreflightError.malformedJSON }
                frames[last].key = try work.withKeyDecode(byteCount: range.count) {
                    try decoder.decode(String.self, from: Data(bytes[range]))
                }
                frames[last].expectsKey = false
                continue
            }
            try work.charge(1)
            let id = entries.count
            entries.append(Entry(range: range, members: byte == 123 ? [:] : nil, elements: byte == 91 ? [] : nil))
            if let last = frames.indices.last {
                let parent = frames[last].id
                if frames[last].object {
                    guard let key = frames[last].key else { throw RouterJSONPreflightError.malformedJSON }
                    if let existing = entries[parent].members?[key] {
                        guard permitsDuplicateKeys else { throw RouterJSONPreflightError.malformedJSON }
                        var values = duplicateMembers[parent]?[key] ?? [existing]
                        values.append(id)
                        duplicateMembers[parent, default: [:]][key] = values
                    }
                    entries[parent].members?[key] = id
                    frames[last].key = nil
                } else { entries[parent].elements?.append(id) }
            } else if id != 0 { throw RouterJSONPreflightError.malformedJSON }
            if compound { frames.append(Frame(id: id, object: byte == 123, expectsKey: byte == 123)) }
        }
        guard !entries.isEmpty, frames.isEmpty else { throw RouterJSONPreflightError.malformedJSON }
        self.entries = entries
        self.duplicateMembers = duplicateMembers
    }

    func range(at path: [any CodingKey], work: inout RouterJSONWorkBudget) throws -> Range<Int> {
        var current = 0
        for key in path {
            try work.charge(1)
            if let members = entries[current].members {
                try work.charge(key.stringValue.utf8.count)
                guard let child = members[key.stringValue] else { throw RouterJSONPreflightError.malformedJSON }
                current = child
            } else if let elements = entries[current].elements, let index = key.intValue,
                      index >= 0, index < elements.count {
                current = elements[index]
            } else { throw RouterJSONPreflightError.malformedJSON }
        }
        return entries[current].range
    }

    /// Walk the known state topology iteratively. An old application's other
    /// schema fields are its migration's responsibility, never route decoders.
    func rejectTransientState(stateKey: String?, work: inout RouterJSONWorkBudget) throws {
        func members(_ ids: [Int], _ name: String, work: inout RouterJSONWorkBudget) throws -> [Int] {
            var result: [Int] = []
            for id in ids {
                try work.charge(name.utf8.count + 1)
                if let duplicates = duplicateMembers[id]?[name] {
                    try work.charge(duplicates.count)
                    result.append(contentsOf: duplicates)
                } else if let child = entries[id].members?[name] { result.append(child) }
            }
            return result
        }
        func elements(_ ids: [Int], work: inout RouterJSONWorkBudget) throws -> [Int] {
            var result: [Int] = []
            for id in ids {
                guard let values = entries[id].elements else { continue }
                try work.charge(values.count)
                result.append(contentsOf: values)
            }
            return result
        }
        let roots = try stateKey.map { try members([0], $0, work: &work) } ?? [0]
        var nodes = try members(roots, "root", work: &work)
        let windowFields = try members(roots, "windows", work: &work)
        let windows = try elements(windowFields, work: &work)
        nodes.append(contentsOf: try members(windows, "node", work: &work))
        let spaces = try members(roots, "immersiveSpace", work: &work)
        nodes.append(contentsOf: try members(spaces, "node", work: &work))
        while let node = nodes.popLast() {
            try work.charge(1)
            let stackWrappers = try members([node], "stack", work: &work)
            let stacks = try members(stackWrappers, "_0", work: &work)
            for key in ["presentationFamily", "alert", "confirmationDialog"] {
                if try !members(stacks, key, work: &work).isEmpty {
                    throw RouterTransientPresentationPersistenceFailure.unsupportedRestoration
                }
            }
            let presentations = try members(stacks, "presentation", work: &work)
            nodes.append(contentsOf: try members(presentations, "node", work: &work))
            let containerWrappers = try members([node], "container", work: &work)
            let containers = try members(containerWrappers, "_0", work: &work)
            let branchFields = try members(containers, "branches", work: &work)
            let branches = try elements(branchFields, work: &work)
            nodes.append(contentsOf: try members(branches, "node", work: &work))
        }
    }

    private static func advanceScalar(_ bytes: [UInt8], cursor: inout Int, work: inout RouterJSONWorkBudget) throws {
        if bytes[cursor] == 34 {
            try work.charge(1)
            cursor += 1
            while cursor < bytes.count {
                let byte = bytes[cursor]
                try work.charge(1)
                cursor += 1
                if byte == 34 { return }
                if byte == 92 {
                    guard cursor < bytes.count else { throw RouterJSONPreflightError.malformedJSON }
                    try work.charge(1)
                    cursor += 1
                }
            }
            throw RouterJSONPreflightError.malformedJSON
        }
        let start = cursor
        while cursor < bytes.count, !whitespace(bytes[cursor]), ![44, 93, 125].contains(bytes[cursor]) {
            try work.charge(1)
            cursor += 1
        }
        guard cursor > start else { throw RouterJSONPreflightError.malformedJSON }
    }

    private static func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
}
