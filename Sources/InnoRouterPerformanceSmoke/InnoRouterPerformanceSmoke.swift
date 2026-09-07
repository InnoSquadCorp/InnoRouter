import Foundation

import InnoRouterCore
import InnoRouterDeepLink
import InnoRouterInspector
import InnoRouterSwiftUI
import InnoRouterTesting

private struct PerformanceRoute: Route, Codable {
    let value: Int
}

private struct PerformanceSample: Codable {
    let name: String
    let iterations: Int
    let medianMilliseconds: Double
    let maximumMilliseconds: Double
    let operationsPerSecond: Double
    let passed: Bool
}

private struct PerformanceReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let configuration: String
    let aggregation: String
    let measurementCount: Int
    let passed: Bool
    let samples: [PerformanceSample]
}

private let expectedSampleNames = [
    "reducer_transition_throughput",
    "snapshot_roundtrip_throughput",
    "deep_link_match_throughput",
    "inspector_record_export_throughput",
    "scenario_capture_off_on_throughput",
    "history_capacity_scaling",
    "catalog_size_scaling",
]
private let clock = ContinuousClock()
private let measurementCount = 5

@main
private enum InnoRouterPerformanceSmoke {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments == ["--self-test"] {
            guard median([100, 1, 3, 2, 4]) == 3,
                  median([]) == nil,
                  expectedSampleNames.count == 7 else {
                throw PerformanceFailure.selfTest
            }
            print("[performance-smoke] Aggregation self-test passed")
            return
        }

        guard arguments.count == 2,
              arguments.first == "--output",
              let output = arguments.last else {
            throw PerformanceFailure.usage
        }

        let samples = try await [
            measure(
                name: expectedSampleNames[0],
                iterations: 20_000,
                maximumMilliseconds: 2_500,
                workload: reducerWorkload
            ),
            measure(
                name: expectedSampleNames[1],
                iterations: 200,
                maximumMilliseconds: 5_000,
                workload: snapshotWorkload
            ),
            measure(
                name: expectedSampleNames[2],
                iterations: 10_000,
                maximumMilliseconds: 3_000,
                workload: deepLinkWorkload
            ),
            measure(
                name: expectedSampleNames[3],
                iterations: 10_000,
                maximumMilliseconds: 10_000,
                workload: inspectorWorkload
            ),
            measure(
                name: expectedSampleNames[4],
                iterations: 1_000,
                maximumMilliseconds: 4_000,
                workload: scenarioCaptureWorkload
            ),
            measure(
                name: expectedSampleNames[5],
                iterations: 512,
                maximumMilliseconds: 4_000,
                workload: historyCapacityWorkload
            ),
            measure(
                name: expectedSampleNames[6],
                iterations: 3_000,
                maximumMilliseconds: 3_000,
                workload: catalogSizeWorkload
            ),
        ]
        let report = PerformanceReport(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            configuration: "release",
            aggregation: "median",
            measurementCount: measurementCount,
            passed: samples.allSatisfy(\.passed),
            samples: samples
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)

        guard report.passed else { throw PerformanceFailure.thresholdExceeded }
    }

    @MainActor
    private static func measure(
        name: String,
        iterations: Int,
        maximumMilliseconds: Double,
        workload: () async throws -> Void
    ) async throws -> PerformanceSample {
        try await workload()
        var measurements: [Double] = []
        measurements.reserveCapacity(measurementCount)
        for _ in 0..<measurementCount {
            let elapsed = try await clock.measure { try await workload() }
            measurements.append(milliseconds(elapsed))
        }
        guard let medianMilliseconds = median(measurements), medianMilliseconds > 0 else {
            throw PerformanceFailure.invalidMeasurement(name)
        }
        return PerformanceSample(
            name: name,
            iterations: iterations,
            medianMilliseconds: medianMilliseconds,
            maximumMilliseconds: maximumMilliseconds,
            operationsPerSecond: Double(iterations) / (medianMilliseconds / 1_000),
            passed: medianMilliseconds <= maximumMilliseconds
        )
    }

    private static func reducerWorkload() throws {
        var state = RouterState<PerformanceRoute>.rootStack
        for index in 0..<10_000 {
            state = try RouterReducer.reduce(.push(.init(value: index)), from: state)
            state = try RouterReducer.reduce(.pop(count: 1), from: state)
        }
        precondition(state == .rootStack)
    }

    private static func snapshotWorkload() throws {
        let codec = try RouterSnapshotCodec<PerformanceRoute>(currentVersion: 1)
        let state = RouterState<PerformanceRoute>.rootStack(
            path: (0..<500).map(PerformanceRoute.init(value:))
        )
        var checksum = 0
        for _ in 0..<200 {
            let data = try codec.encode(state)
            checksum += try codec.decode(data).root == state.root ? data.count : 0
        }
        precondition(checksum > 0)
    }

    private static func deepLinkWorkload() {
        let mappings = (0..<256).map { (index: Int) -> DeepLinkMapping<Int> in
            let pattern = "/perf/" + String(index)
            return DeepLinkMapping<Int>(pattern) { _ -> Int? in index }
        }
        let matcher = DeepLinkMatcher<Int>(
            configuration: .init(diagnosticsMode: .disabled)
        ) {
            mappings
        }
        var checksum = 0
        for _ in 0..<10_000 {
            checksum += matcher.match("innorouter://host/perf/255") ?? 0
        }
        precondition(checksum == 2_550_000)
    }

    @MainActor
    private static func inspectorWorkload() throws {
        let recorder = RouterInspectorRecorder(capacity: 5_000)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        for index in 0..<10_000 {
            recorder.record(
                domain: .router,
                description: .init(
                    name: "transition.committed",
                    outcome: .accepted,
                    metadata: ["sequence": String(index)]
                ),
                timestamp: timestamp
            )
        }
        let data = try recorder.encodedSnapshot(generatedAt: timestamp)
        precondition(recorder.entries.count == 5_000 && !data.isEmpty)
    }

    @MainActor
    private static func scenarioCaptureWorkload() async {
        let withoutCapture = RouterStore<PerformanceRoute>()
        for index in 0..<500 {
            _ = await withoutCapture.perform(.push(.init(value: index)))
            _ = await withoutCapture.perform(.pop(count: 1))
        }
        let withCapture = RouterStore<PerformanceRoute>()
        let recorder = RouterScenarioRecorder(store: withCapture, capacity: 1_000)
        for index in 0..<500 {
            _ = await withCapture.perform(.push(.init(value: index)))
            _ = await withCapture.perform(.pop(count: 1))
        }
        let fixture = recorder.stop()
        precondition(fixture.steps.count == 1_000)
    }

    @MainActor
    private static func historyCapacityWorkload() async {
        var checksum = 0
        for capacity in [2, 64, 256, 1_024] {
            let store = RouterStore<PerformanceRoute>()
            let history = RouterHistory(
                store: store,
                configuration: .init(capacity: capacity)
            )
            for index in 0..<128 {
                _ = await store.perform(.push(.init(value: index)))
            }
            checksum += history.entries.count
            history.stop()
        }
        precondition(checksum > 0)
    }

    private static func catalogSizeWorkload() {
        var checksum = 0
        for size in [10, 100, 1_000] {
            let entries = (0..<size).map { index in
                DeepLinkRouteCatalogEntry(
                    declarationNamespace: "PerformanceRoute",
                    routeCase: "route\(index)",
                    pattern: "/perf/\(index)"
                )
            }
            let catalog = DeepLinkRouteCatalog(
                schemes: ["innorouter"],
                hosts: ["host"],
                entries: entries
            )
            let url = URL(string: "innorouter://host/perf/\(size - 1)")!
            for _ in 0..<1_000 {
                checksum += catalog.supportsPureResolution(of: url) ? 1 : 0
            }
        }
        precondition(checksum == 3_000)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return nil
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

private enum PerformanceFailure: Error, CustomStringConvertible {
    case invalidMeasurement(String)
    case selfTest
    case thresholdExceeded
    case usage

    var description: String {
        switch self {
        case .invalidMeasurement(let name): "invalid measurement for \(name)"
        case .selfTest: "aggregation self-test failed"
        case .thresholdExceeded: "one or more performance thresholds were exceeded"
        case .usage: "usage: InnoRouterPerformanceSmoke --output <report.json>"
        }
    }
}
