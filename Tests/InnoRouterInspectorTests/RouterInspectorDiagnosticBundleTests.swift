import Foundation
import Testing

import InnoRouter
@testable import InnoRouterInspector

@Suite("Inspector diagnostic bundle import")
@MainActor
struct RouterInspectorDiagnosticBundleTests {
    @Test("Support bundles reopen with environment identity, bookmarks, and bounded history")
    func roundTrip() throws {
        let source = RouterInspectorRecorder()
        source.record(domain: .router, description: .init(name: "first"))
        source.record(domain: .router, description: .init(name: "second"))
        source.toggleBookmark(source.entries[1].id)
        let data = try source.encodedDiagnosticBundle(platform: .visionOS, frameworkVersion: "6.0.0")
        let target = RouterInspectorRecorder(capacity: 1)

        let bundle = try target.importDiagnosticBundle(from: data)

        #expect(bundle.platform == .visionOS)
        #expect(bundle.frameworkVersion == "6.0.0")
        #expect(bundle.snapshot.entries == source.entries)
        #expect(target.entries == [source.entries[1]])
        #expect(target.bookmarkedEntryIDs == source.bookmarkedEntryIDs)
        #expect(try RouterInspectorImportPreflight.isDiagnosticBundle(data, limits: .default))
        #expect(try !RouterInspectorImportPreflight.isDiagnosticBundle(source.encodedSnapshot(), limits: .default))
    }

    @Test("Unsupported bundle formats fail before decoding entries and preserve the timeline", arguments: [0, -1, 2, Int.max])
    func unknownFormat(version: Int) throws {
        let recorder = RouterInspectorRecorder()
        recorder.record(domain: .application, description: .init(name: "sentinel"))
        recorder.toggleBookmark(recorder.entries[0].id)
        let original = recorder.snapshot(generatedAt: .distantPast)
        let data = Data("{\"formatVersion\":\(version),\"snapshot\":{\"entries\":[]}}".utf8)

        do {
            _ = try JSONDecoder().decode(RouterInspectorDiagnosticBundle.self, from: data)
            Issue.record("Expected unsupported bundle format")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.last?.stringValue == "formatVersion")
        }
        do {
            try recorder.importDiagnosticBundle(from: data)
            Issue.record("Expected unsupported bundle format")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.last?.stringValue == "formatVersion")
        }
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
    }

    @Test("Bundle byte and entry limits run before entry decoding")
    func preflight() {
        let recorder = RouterInspectorRecorder(importLimits: .init(maximumEncodedByteCount: 1_024, maximumEntryCount: 1))
        #expect(throws: RouterInspectorImportError.encodedDataTooLarge(actualByteCount: 1_025, maximumByteCount: 1_024)) {
            try recorder.importDiagnosticBundle(from: Data(repeating: 0x20, count: 1_025))
        }
        // Neither object is a decodable entry; the count error must win.
        let data = Data(#"{"formatVersion":1,"snapshot":{"entries":[{},{}]}}"#.utf8)
        #expect(throws: RouterInspectorImportError.tooManyEntries(actualCount: 2, maximumCount: 1)) {
            try recorder.importDiagnosticBundle(from: data)
        }
        #expect(recorder.entries.isEmpty)
    }

    @Test("Escaped envelope keys cannot bypass entry limits")
    func escapedKeys() {
        let recorder = RouterInspectorRecorder(importLimits: .init(maximumEntryCount: 1))
        let data = Data(#"{"formatVersion":1,"snap\u0073hot":{"entri\u0065s":[{},{}]}}"#.utf8)
        #expect(throws: RouterInspectorImportError.tooManyEntries(actualCount: 2, maximumCount: 1)) {
            try recorder.importDiagnosticBundle(from: data)
        }
    }

    @Test("Duplicate or misplaced envelope keys fail closed", arguments: [
        #"{"formatVersion":1,"formatVersion":2,"snapshot":{"entries":[]}}"#,
        #"{"formatVersion":1,"snapshot":{"entries":[]},"snapshot":{"entries":[{},{}]}}"#,
        #"{"formatVersion":1,"snapshot":{"entries":[],"entri\u0065s":[{},{}]}}"#,
        #"{"formatVersion":1,"other":{"entries":[]},"snapshot":{}}"#,
        #"{"formatVersion":1,"snapshot":{"entries":[{},]}}"#,
    ])
    func ambiguousEnvelope(json: String) {
        let recorder = RouterInspectorRecorder()
        #expect(throws: RouterInspectorImportError.malformedSnapshotEnvelope) {
            try recorder.importDiagnosticBundle(from: Data(json.utf8))
        }
        #expect(recorder.entries.isEmpty)
    }

    @Test("A bundle append rejects duplicate IDs atomically")
    func duplicateAppend() throws {
        let recorder = RouterInspectorRecorder()
        recorder.record(domain: .router, description: .init(name: "existing"))
        let entry = recorder.entries[0]
        let data = try recorder.encodedDiagnosticBundle()
        #expect(throws: RouterInspectorImportError.duplicateEntryID(entry.id)) {
            try recorder.importDiagnosticBundle(from: data, policy: .append)
        }
        #expect(recorder.entries == [entry])
    }

    @Test("Replacing a timeline clears live timing correlation")
    func replaceClearsTiming() throws {
        let recorder = RouterInspectorRecorder()
        recorder.record(
            domain: .router,
            description: .init(name: "transition.started", metadata: ["transitionID": "old"]),
            timestamp: Date(timeIntervalSince1970: 1)
        )
        try recorder.importSnapshot(.init(entries: []))
        recorder.record(
            domain: .router,
            description: .init(name: "transition.committed", metadata: ["transitionID": "old"]),
            timestamp: Date(timeIntervalSince1970: 2)
        )
        #expect(recorder.entries[0].metadata["durationMilliseconds"] == nil)
        #expect(recorder.entries[0].metadata["elapsedSincePreviousMilliseconds"] == nil)
    }

    @Test("Snapshot values discard bookmarks that do not identify an entry")
    func orphanBookmarks() throws {
        let orphan = UUID()
        let snapshot = RouterInspectorSnapshot(entries: [], bookmarkedEntryIDs: [orphan])
        #expect(snapshot.bookmarkedEntryIDs.isEmpty)
        let data = Data("{\"generatedAt\":0,\"entries\":[],\"bookmarkedEntryIDs\":[\"\(orphan)\"]}".utf8)
        #expect(try JSONDecoder().decode(RouterInspectorSnapshot.self, from: data).bookmarkedEntryIDs.isEmpty)
    }
}
