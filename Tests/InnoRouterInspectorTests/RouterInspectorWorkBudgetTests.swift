import Foundation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterInspector

@Suite("Inspector cumulative file-import admission")
@MainActor
struct RouterInspectorWorkBudgetTests {
    @Test("Classification and decoding share a cap before the custom decoder runs")
    func classificationDoesNotResetWork() throws {
        let snapshot = RouterInspectorSnapshot(generatedAt: .distantPast, entries: [])
        let bundle = RouterInspectorDiagnosticBundle(platform: .macOS, snapshot: snapshot)
        let data = try JSONEncoder().encode(bundle)
        func limits(_ cap: Int) -> RouterInspectorImportLimits { .init(maximumJSONWorkUnits: cap) }
        func minimum(_ operation: (RouterInspectorImportLimits) throws -> Void) throws -> Int {
            var low = 0
            var high = 1_000_000
            while low < high {
                let middle = low + (high - low) / 2
                do { try operation(limits(middle)); high = middle }
                catch RouterInspectorImportError.resourceLimit { low = middle + 1 }
            }
            try operation(limits(low))
            return low
        }
        let classification = try minimum { _ = try RouterInspectorImportPreflight.isDiagnosticBundle(data, limits: $0) }
        let decoding = try minimum { try RouterInspectorImportPreflight.validate(data, limits: $0, diagnosticBundle: true) }
        let combined = try minimum { _ = try RouterInspectorImportPreflight.classifyAndValidate(data, limits: $0) }
        #expect(combined > max(classification, decoding))
        let decoderCalls = InspectorWorkDecoderCounter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            decoderCalls.increment()
            return Date(timeIntervalSinceReferenceDate: try decoder.singleValueContainer().decode(Double.self))
        }
        let rejected = RouterInspectorRecorder(importLimits: limits(max(classification, decoding)))
        #expect(throws: RouterInspectorImportError.self) { try rejected.importDetectedData(from: data, decoder: decoder) }
        #expect(decoderCalls.count == 0)
        #expect(rejected.entries.isEmpty)
        let accepted = RouterInspectorRecorder(importLimits: limits(combined))
        #expect(try accepted.importDetectedData(from: data, decoder: decoder) == snapshot)
        #expect(decoderCalls.count == 1)
    }

    @Test("Shared resource configuration retains Inspector's distinct transport and retention bounds")
    func configurationMapping() throws {
        let budget = RouterResourceBudget(
            inspectorImport: .init(maximumEncodedBytes: 1_024, maximumDepth: 12, maximumTokens: 256),
            maximumInspectorEntries: 4, maximumRecordedInspectorEntries: 2,
            maximumInspectorExportBytes: 512, maximumJSONWorkUnits: 64, maximumJSONKeyDecodes: 8
        )
        let recorder = try RouterInspectorRecorder(resourceBudget: budget)
        #expect(recorder.capacity == 2)
        #expect(recorder.importLimits.maximumEntryCount == 4)
        #expect(recorder.importLimits.maximumEncodedByteCount == 1_024)
        #expect(recorder.importLimits.maximumJSONWorkUnits == 64)
        #expect(recorder.importLimits.maximumJSONKeyDecodes == 8)
        #expect(recorder.exportLimits.maximumEncodedByteCount == 512)
    }
}

private final class InspectorWorkDecoderCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}
