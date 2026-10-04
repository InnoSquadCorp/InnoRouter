import Foundation
import Testing

import InnoRouterCore
import InnoRouterInspector

@Suite("Inspector encoded export limits")
@MainActor
struct RouterInspectorExportLimitTests {
    @Test("Default snapshot exports reject a single oversized formatted entry")
    func defaultSnapshotExportIsBounded() {
        let recorder = oversizedRecorder()
        #expect(throws: (any Error).self) {
            try recorder.encodedSnapshot(generatedAt: .distantPast)
        }
    }

    @Test("Default diagnostic exports reject a single oversized formatted entry")
    func defaultDiagnosticExportIsBounded() {
        let recorder = oversizedRecorder()
        #expect(throws: (any Error).self) {
            try recorder.encodedDiagnosticBundle(platform: .macOS, generatedAt: .distantPast)
        }
    }

    @Test("Snapshot byte limits accept the exact encoder output and reject one extra byte", arguments: [false, true])
    func exactSnapshotBoundary(customized: Bool) throws {
        let snapshot = fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if customized {
            encoder.outputFormatting.insert(.prettyPrinted)
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode("custom-date:\(date.timeIntervalSince1970)")
            }
        }
        let expected = try encoder.encode(snapshot)
        let exact = try recorder(snapshot, maximumBytes: expected.count)
        #expect(try exact.encodedSnapshot(generatedAt: snapshot.generatedAt, encoder: encoder) == expected)

        let over = try recorder(snapshot, maximumBytes: expected.count - 1)
        #expect(throws: RouterInspectorExportFailure.encodedDataTooLarge(
            actualByteCount: expected.count, maximumByteCount: expected.count - 1
        )) {
            try over.encodedSnapshot(generatedAt: snapshot.generatedAt, encoder: encoder)
        }
        #expect(over.snapshot(generatedAt: snapshot.generatedAt) == snapshot)
    }

    @Test("Diagnostic limits count the complete deterministic encoded envelope")
    func exactDiagnosticBoundary() throws {
        let snapshot = fixture()
        let bundle = RouterInspectorDiagnosticBundle(
            frameworkVersion: "test-version", platform: .visionOS, snapshot: snapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(bundle)
        let exact = try recorder(snapshot, maximumBytes: expected.count)
        #expect(try exact.encodedDiagnosticBundle(
            platform: .visionOS, frameworkVersion: "test-version", generatedAt: snapshot.generatedAt
        ) == expected)

        let over = try recorder(snapshot, maximumBytes: expected.count - 1)
        #expect(throws: RouterInspectorExportFailure.encodedDataTooLarge(
            actualByteCount: expected.count, maximumByteCount: expected.count - 1
        )) {
            try over.encodedDiagnosticBundle(
                platform: .visionOS, frameworkVersion: "test-version", generatedAt: snapshot.generatedAt
            )
        }
        #expect(over.snapshot(generatedAt: snapshot.generatedAt) == snapshot)
    }

    @Test("Bundle metadata alone can exceed the export limit with no recorded entries")
    func emptyTimelineMetadataIsBounded() throws {
        let snapshot = RouterInspectorSnapshot(generatedAt: .distantPast, entries: [])
        let maximum = try JSONEncoder().encode(snapshot).count
        let recorder = RouterInspectorRecorder(exportLimits: .init(maximumEncodedByteCount: maximum))
        #expect(try recorder.encodedSnapshot(generatedAt: snapshot.generatedAt).count == maximum)
        let expected = try JSONEncoder().encode(recorder.diagnosticBundle(
            platform: .macOS, frameworkVersion: "private-framework-version", generatedAt: snapshot.generatedAt
        )).count
        #expect(expected > maximum)
        #expect(throws: RouterInspectorExportFailure.encodedDataTooLarge(
            actualByteCount: expected, maximumByteCount: maximum
        )) {
            try recorder.encodedDiagnosticBundle(
                platform: .macOS, frameworkVersion: "private-framework-version", generatedAt: snapshot.generatedAt
            )
        }
        #expect(recorder.entries.isEmpty)
    }

    @Test("Export rejection preserves entries, bookmarks, pause settings and timing", arguments: [false, true])
    func rejectedExportIsAtomic(diagnostic: Bool) throws {
        let recorder = RouterInspectorRecorder(exportLimits: .init(maximumEncodedByteCount: 1))
        recorder.setPauseOnRejection(true)
        recorder.record(domain: .router, description: .init(
            name: "transition.started", metadata: ["transitionID": "correlation", "private": "private-payload"]
        ), timestamp: Date(timeIntervalSince1970: 1))
        recorder.toggleBookmark(recorder.entries[0].id)
        recorder.pause()
        let original = recorder.snapshot(generatedAt: .distantPast)
        do {
            if diagnostic {
                _ = try recorder.encodedDiagnosticBundle(platform: .macOS, generatedAt: .distantPast)
            } else {
                _ = try recorder.encodedSnapshot(generatedAt: .distantPast)
            }
            Issue.record("Expected export limit rejection")
        } catch let error as RouterInspectorExportFailure {
            #expect(error.code == .encodedDataTooLarge)
            #expect(error.details.maximumByteCount == 1)
            #expect(try #require(error.details.actualByteCount) > 1)
            #expect(error.description == "innorouter.inspector.encodedDataTooLarge")
            let encodedError = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
            for payload in ["private-payload", "correlation", "transition.started", original.entries[0].id.uuidString] {
                #expect(!String(reflecting: error).contains(payload))
                #expect(!encodedError.contains(payload))
            }
        }
        #expect(recorder.snapshot(generatedAt: .distantPast) == original)
        #expect(recorder.isPaused)
        #expect(recorder.pauseOnRejection)
        recorder.resume()
        recorder.record(domain: .router, description: .init(
            name: "transition.committed", metadata: ["transitionID": "correlation"]
        ), timestamp: Date(timeIntervalSince1970: 3))
        #expect(recorder.entries.last?.metadata["durationMilliseconds"] == "2000.000")
        #expect(recorder.entries.last?.metadata["elapsedSincePreviousMilliseconds"] == "2000.000")
        #expect(recorder.bookmarkedEntryIDs == original.bookmarkedEntryIDs)
    }

    @Test("Custom encoder errors propagate unchanged before encoded-size validation")
    func customEncoderFailureIsPreserved() throws {
        let snapshot = fixture()
        let recorder = try recorder(snapshot, maximumBytes: 1)
        recorder.pause()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { _, _ in throw EncodingSentinel.expected }
        #expect(throws: EncodingSentinel.expected) {
            try recorder.encodedSnapshot(generatedAt: snapshot.generatedAt, encoder: encoder)
        }
        #expect(recorder.snapshot(generatedAt: snapshot.generatedAt) == snapshot)
        #expect(recorder.isPaused)
    }

    @Test("Export limits normalize nonpositive configuration to a finite one-byte minimum", arguments: [-1, 0, 1, 128])
    func normalizedLimits(value: Int) {
        #expect(RouterInspectorExportLimits(maximumEncodedByteCount: value).maximumEncodedByteCount == max(1, value))
        #expect(RouterInspectorExportLimits.default.maximumEncodedByteCount == 8 * 1_024 * 1_024)
        #expect(RouterInspectorRecorder().exportLimits == .default)
    }

    @Test("Import bytes, export bytes and recorder entry capacity are independent")
    func independentLimits() throws {
        let snapshot = fixture()
        let expectedCount = try JSONEncoder().encode(snapshot).count
        let source = RouterInspectorRecorder(
            capacity: 1,
            importLimits: .init(maximumEncodedByteCount: 1),
            exportLimits: .init(maximumEncodedByteCount: expectedCount)
        )
        try source.importSnapshot(snapshot)
        let data = try source.encodedSnapshot(generatedAt: snapshot.generatedAt)
        #expect(data.count == expectedCount)
        #expect(throws: RouterInspectorImportError.encodedDataTooLarge(
            actualByteCount: expectedCount, maximumByteCount: 1
        )) {
            try source.importSnapshot(from: data)
        }
        let target = RouterInspectorRecorder(
            importLimits: .init(maximumEncodedByteCount: expectedCount),
            exportLimits: .init(maximumEncodedByteCount: 1)
        )
        try target.importSnapshot(from: data)
        #expect(target.snapshot(generatedAt: snapshot.generatedAt) == snapshot)
        #expect(throws: RouterInspectorExportFailure.encodedDataTooLarge(
            actualByteCount: expectedCount, maximumByteCount: 1
        )) {
            try target.encodedSnapshot(generatedAt: snapshot.generatedAt)
        }
    }

    @Test("Future export failure codes remain representable and round-trip without payloads")
    func extensibleFailure() throws {
        let error = RouterInspectorExportFailure(
            code: .init(rawValue: "innorouter.inspector.futureLimit"),
            details: .init(actualByteCount: 25, maximumByteCount: 24)
        )
        #expect(try JSONDecoder().decode(
            RouterInspectorExportFailure.self, from: JSONEncoder().encode(error)
        ) == error)
        #expect(String(describing: error) == error.code.rawValue)
        #expect(RouterInspectorExportFailure(code: error.code).details == .init())
    }

    private enum EncodingSentinel: Error { case expected }

    private func fixture() -> RouterInspectorSnapshot {
        let entry = RouterInspectorEntry(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            timestamp: Date(timeIntervalSince1970: 10), domain: .application,
            name: "custom.formatted", outcome: .informational,
            metadata: ["detail": "private-payload/한글/👩🏽‍💻/\"escaped\"/\n"]
        )
        return RouterInspectorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 20), entries: [entry], bookmarkedEntryIDs: [entry.id]
        )
    }

    private func recorder(_ snapshot: RouterInspectorSnapshot, maximumBytes: Int) throws -> RouterInspectorRecorder {
        let recorder = RouterInspectorRecorder(exportLimits: .init(maximumEncodedByteCount: maximumBytes))
        try recorder.importSnapshot(snapshot)
        return recorder
    }

    private func oversizedRecorder() -> RouterInspectorRecorder {
        let recorder = RouterInspectorRecorder(capacity: 1)
        recorder.record(domain: .application, description: .init(
            name: "custom.formatted",
            metadata: ["detail": String(repeating: "x", count: 8 * 1_024 * 1_024)]
        ))
        return recorder
    }
}
