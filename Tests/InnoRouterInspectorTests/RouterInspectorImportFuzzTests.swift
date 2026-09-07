import Foundation
import Testing

import InnoRouterInspector

@Suite("Inspector import mutation")
@MainActor
struct RouterInspectorImportFuzzTests {
    @Test("Corrupted exports either import within bounds or leave the recorder unchanged", arguments: [false, true])
    func corruptedExportsAreAtomic(diagnosticBundle: Bool) throws {
        let source = RouterInspectorSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            entries: (0..<4).map { index in
                RouterInspectorEntry(
                    id: Self.uuid(index + 1),
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    domain: index.isMultiple(of: 2) ? .router : .application,
                    name: "event-\(index)",
                    outcome: .informational,
                    metadata: ["sequence": String(index)]
                )
            }
        )
        let validData = try diagnosticBundle
            ? JSONEncoder().encode(RouterInspectorDiagnosticBundle(platform: .macOS, snapshot: source))
            : JSONEncoder().encode(source)
        var generator = InspectorMutationGenerator(seed: 0x1A5E_C70F)

        for iteration in 0..<2_000 {
            let recorder = RouterInspectorRecorder(
                capacity: 16,
                importLimits: .init(
                    maximumEncodedByteCount: 4_096,
                    maximumEntryCount: 16
                )
            )
            recorder.record(
                domain: .application,
                description: .init(name: "sentinel")
            )
            let originalEntries = recorder.entries
            let mutated = generator.mutate(validData, iteration: iteration)

            do {
                let imported = try diagnosticBundle
                    ? recorder.importDiagnosticBundle(from: mutated).snapshot
                    : recorder.importSnapshot(from: mutated)
                #expect(imported.entries.count <= 16)
                #expect(recorder.entries == imported.entries)
            } catch {
                #expect(recorder.entries == originalEntries)
            }
        }
    }

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

private struct InspectorMutationGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func mutate(_ input: Data, iteration: Int) -> Data {
        var bytes = Array(input)
        let operationCount = 1 + Int(next() % 12)

        for _ in 0..<operationCount {
            switch next() % 5 {
            case 0 where !bytes.isEmpty:
                bytes.remove(at: index(in: bytes))
            case 1 where !bytes.isEmpty:
                bytes[index(in: bytes)] ^= UInt8(truncatingIfNeeded: next())
            case 2 where bytes.count < 4_096:
                bytes.insert(UInt8(truncatingIfNeeded: next()), at: insertionIndex(in: bytes))
            case 3 where bytes.count > 1:
                let upperBound = 1 + index(in: bytes)
                bytes.removeSubrange(upperBound..<bytes.count)
            default:
                if bytes.count < 4_080 {
                    bytes.append(contentsOf: Array("{\"entries\":[]}".utf8))
                }
            }
        }

        // Periodically preserve a valid export to exercise the success path
        // using the same deterministic corpus.
        return iteration.isMultiple(of: 97) ? input : Data(bytes)
    }

    private mutating func index(in bytes: [UInt8]) -> Int {
        Int(next() % UInt64(bytes.count))
    }

    private mutating func insertionIndex(in bytes: [UInt8]) -> Int {
        Int(next() % UInt64(bytes.count + 1))
    }

    private mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
