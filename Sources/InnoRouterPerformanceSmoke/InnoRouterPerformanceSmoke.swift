import Foundation
import Darwin.Mach
import InnoRouter
import InnoRouterEffects

private struct SmokeRoute: Route, Codable {
    let id: Int
}

private struct SmokeSample: Codable {
    let name: String
    let smallInput: Int
    let largeInput: Int
    let smallMilliseconds: Double
    let largeMilliseconds: Double
    let ratio: Double
    let threshold: Double
    /// Generous wall-clock cap on the large-input run, in
    /// milliseconds. Catches catastrophic absolute-time
    /// regressions that the relative `ratio <= threshold` check
    /// misses when both small and large slow down proportionally
    /// (for example, an unrelated CI runner saturation event).
    /// `nil` opts out of the absolute check for samples whose
    /// timing varies too widely across host machines.
    let largeMaxMilliseconds: Double?
    let passed: Bool
}

private struct SmokeReport: Codable {
    let generatedAt: String
    let aggregation: String
    let measurementPairs: Int
    let passed: Bool
    let memoryFootprint: SmokeMemoryFootprint
    let samples: [SmokeSample]
}

private struct SmokeMemoryFootprint: Codable {
    let residentBytes: UInt64?
}

private let clock = ContinuousClock()
private let measurementPairCount = 5

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty,
          values.allSatisfy({ $0.isFinite && $0 > 0 })
    else {
        return nil
    }

    let sortedValues = values.sorted()
    let middle = sortedValues.count / 2
    if sortedValues.count.isMultiple(of: 2) {
        return (sortedValues[middle - 1] + sortedValues[middle]) / 2
    }
    return sortedValues[middle]
}

@MainActor
private func measureMilliseconds(
    warmup: Int = 1,
    samples: Int = 3,
    _ body: () -> Void
) -> Double {
    for _ in 0..<warmup {
        body()
    }

    var durations: [Double] = []
    durations.reserveCapacity(samples)
    for _ in 0..<samples {
        let duration = clock.measure {
            body()
        }
        var milliseconds = Double(duration.components.seconds) * 1_000
        milliseconds += Double(duration.components.attoseconds) / 1_000_000_000_000_000
        durations.append(milliseconds)
    }

    return median(durations) ?? 0
}

private func makeRoutes(_ count: Int) -> [SmokeRoute] {
    (0..<count).map { SmokeRoute(id: $0) }
}

@MainActor
private func measureNavigationReplace(routeCount: Int) -> Double {
    let routes = makeRoutes(routeCount)
    let store = NavigationStore<SmokeRoute>()
    return measureMilliseconds {
        _ = store.execute(.replace(routes))
        _ = store.execute(.popToRoot)
        _ = store.execute(.replace([]))
    }
}

@MainActor
private func measureModalQueue(queueCount: Int) -> Double {
    let routes = makeRoutes(queueCount)
    let store = ModalStore<SmokeRoute>()
    return measureMilliseconds {
        for route in routes {
            store.present(route, style: .sheet)
        }
        for _ in routes {
            store.dismissCurrent()
        }
    }
}

@MainActor
private func makeNavigationMiddlewares(_ count: Int) -> [NavigationMiddlewareRegistration<SmokeRoute>] {
    (0..<count).map { index in
        .init(
            middleware: AnyNavigationMiddleware(
                willExecute: { command, _ in
                    if case .push(let route) = command, route.id % max(index + 2, 2) == 0 {
                        return .proceed(.push(SmokeRoute(id: route.id + 1)))
                    }
                    return .proceed(command)
                }
            ),
            debugName: "perf-nav-\(index)"
        )
    }
}

@MainActor
private func measureMiddlewareChain(chainCount: Int) -> Double {
    let store = NavigationStore<SmokeRoute>(
        configuration: NavigationStoreConfiguration(
            middlewares: makeNavigationMiddlewares(chainCount)
        )
    )
    return measureMilliseconds {
        for index in 0..<200 {
            _ = store.execute(.replace([]))
            _ = store.execute(.push(SmokeRoute(id: index)))
        }
        _ = store.execute(.replace([]))
    }
}

private func makePipeline(mappingCount: Int) -> FlowDeepLinkPipeline<SmokeRoute> {
    let mappings = (0..<mappingCount).map { index in
        DeepLinkMapping<FlowPlan<SmokeRoute>>("/perf/\(index)") { _ in
            FlowPlan(steps: [.push(SmokeRoute(id: index))])
        }
    }

    return FlowDeepLinkPipeline(
        allowedSchemes: ["myapp"],
        allowedHosts: ["app"],
        matcher: DeepLinkMatcher {
            mappings
        }
    )
}

@MainActor
private func measureDeepLinkPipeline(mappingCount: Int) -> Double {
    let pipeline = makePipeline(mappingCount: mappingCount)
    let store = FlowStore<SmokeRoute>()
    let handler = FlowDeepLinkEffectHandler(
        pipeline: pipeline,
        applier: store
    )
    let url = URL(string: "myapp://app/perf/\(mappingCount - 1)")!

    // Keep setup out of the timed block so this measurement reflects repeated
    // deep-link handling hot-path cost, matching the other smoke scenarios.
    return measureMilliseconds {
        for _ in 0..<200 {
            _ = handler.handle(url)
        }
    }
}

private struct PairedMeasurementSummary {
    let smallMilliseconds: Double
    let largeMilliseconds: Double
    let medianPairRatio: Double
}

private func pairedMedianMeasurement(
    smallInput: Int,
    largeInput: Int,
    pairCount: Int = measurementPairCount,
    measure: (Int) -> Double
) -> PairedMeasurementSummary? {
    guard pairCount > 0 else { return nil }

    var smallMeasurements: [Double] = []
    var largeMeasurements: [Double] = []
    var pairRatios: [Double] = []
    smallMeasurements.reserveCapacity(pairCount)
    largeMeasurements.reserveCapacity(pairCount)
    pairRatios.reserveCapacity(pairCount)

    for pairIndex in 0..<pairCount {
        let small: Double
        let large: Double
        if pairIndex.isMultiple(of: 2) {
            small = measure(smallInput)
            large = measure(largeInput)
        } else {
            large = measure(largeInput)
            small = measure(smallInput)
        }

        let pairRatio = large / small
        guard small.isFinite, small > 0,
              large.isFinite, large > 0,
              pairRatio.isFinite, pairRatio > 0
        else {
            return nil
        }
        smallMeasurements.append(small)
        largeMeasurements.append(large)
        pairRatios.append(pairRatio)
    }

    guard smallMeasurements.count == pairCount,
          largeMeasurements.count == pairCount,
          pairRatios.count == pairCount,
          let smallMedian = median(smallMeasurements),
          let largeMedian = median(largeMeasurements),
          let medianPairRatio = median(pairRatios)
    else {
        return nil
    }

    return PairedMeasurementSummary(
        smallMilliseconds: smallMedian,
        largeMilliseconds: largeMedian,
        medianPairRatio: medianPairRatio
    )
}

private func runAggregationSelfTest() -> Bool {
    func deterministicSample(
        name: String,
        smallValues: [Double],
        largeValues: [Double],
        threshold: Double,
        largeMaxMilliseconds: Double? = nil
    ) -> SmokeSample {
        var smallIndex = 0
        var largeIndex = 0
        return makeSample(
            name: name,
            smallInput: 1,
            largeInput: 2,
            threshold: threshold,
            largeMaxMilliseconds: largeMaxMilliseconds
        ) { input in
            if input == 1 {
                defer { smallIndex += 1 }
                return smallValues[smallIndex]
            }
            defer { largeIndex += 1 }
            return largeValues[largeIndex]
        }
    }

    let smallValues = [1.0, 100.0, 1.0, 100.0, 1.0]
    let largeValues = [2.0, 200.0, 2.0, 200.0, 2.0]
    var smallIndex = 0
    var largeIndex = 0
    var callOrder: [Int] = []

    let summary = pairedMedianMeasurement(smallInput: 1, largeInput: 2) { input in
        callOrder.append(input)
        if input == 1 {
            defer { smallIndex += 1 }
            return smallValues[smallIndex]
        }
        defer { largeIndex += 1 }
        return largeValues[largeIndex]
    }

    let expectedOrder = [1, 2, 2, 1, 1, 2, 2, 1, 1, 2]
    guard summary?.smallMilliseconds == 1,
          summary?.largeMilliseconds == 2,
          summary?.medianPairRatio == 2,
          callOrder == expectedOrder,
          median([2, 2, 100, 100, 100]) == 100,
          median([1, 0, 1]) == nil,
          median([1, .nan, 1]) == nil,
          median([1, .infinity, 1]) == nil
    else {
        return false
    }

    let asymmetricSample = deterministicSample(
        name: "asymmetric_pair_regression_self_test",
        smallValues: [1_000, 1_000, 1, 1_000, 1_000],
        largeValues: [4_000, 4_000, 4, 1, 1],
        threshold: 3.8
    )

    guard asymmetricSample.smallMilliseconds == 1_000,
          asymmetricSample.largeMilliseconds == 4,
          asymmetricSample.ratio == 4,
          asymmetricSample.passed == false
    else {
        return false
    }

    let toleratedOutliers = deterministicSample(
        name: "two_pair_outlier_self_test",
        smallValues: [1, 1, 1, 1, 1],
        largeValues: [4, 4, 1, 1, 1],
        threshold: 3.8
    )
    let boundarySample = deterministicSample(
        name: "threshold_and_cap_boundary_self_test",
        smallValues: [1, 1, 1, 1, 1],
        largeValues: [3.8, 3.8, 3.8, 3.8, 3.8],
        threshold: 3.8,
        largeMaxMilliseconds: 3.8
    )
    let capExceeded = deterministicSample(
        name: "absolute_cap_self_test",
        smallValues: [1, 1, 1, 1, 1],
        largeValues: [2, 2, 2, 2, 2],
        threshold: 3,
        largeMaxMilliseconds: 1.99
    )
    guard toleratedOutliers.ratio == 1,
          toleratedOutliers.passed,
          boundarySample.ratio == 3.8,
          boundarySample.largeMilliseconds == 3.8,
          boundarySample.passed,
          capExceeded.ratio == 2,
          capExceeded.passed == false
    else {
        return false
    }

    var invalidCallCount = 0
    let invalidSummary = pairedMedianMeasurement(smallInput: 1, largeInput: 2) { input in
        defer { invalidCallCount += 1 }
        return invalidCallCount == 4 ? .nan : Double(input)
    }
    return invalidSummary == nil
}

private func makeSample(
    name: String,
    smallInput: Int,
    largeInput: Int,
    threshold: Double,
    largeMaxMilliseconds: Double? = nil,
    measure: (Int) -> Double
) -> SmokeSample {
    let measurement = pairedMedianMeasurement(
        smallInput: smallInput,
        largeInput: largeInput,
        measure: measure
    )
    let small = measurement?.smallMilliseconds ?? 0
    let large = measurement?.largeMilliseconds ?? 0
    let ratio = measurement?.medianPairRatio ?? .infinity
    let absolutePassed: Bool
    if let cap = largeMaxMilliseconds {
        absolutePassed = large <= cap
    } else {
        absolutePassed = true
    }
    return SmokeSample(
        name: name,
        smallInput: smallInput,
        largeInput: largeInput,
        smallMilliseconds: small,
        largeMilliseconds: large,
        ratio: ratio,
        threshold: threshold,
        largeMaxMilliseconds: largeMaxMilliseconds,
        passed: measurement != nil && ratio <= threshold && absolutePassed
    )
}

private func outputPath() -> String? {
    let arguments = CommandLine.arguments.dropFirst()
    var iterator = arguments.makeIterator()

    while let argument = iterator.next() {
        if argument == "--output" {
            return iterator.next()
        }
    }

    return nil
}

private func writeReport(_ report: SmokeReport, to path: String?) throws {
    guard let path else {
        let data = try JSONEncoder.prettyPrinted.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
    }

    let outputURL = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    let data = try JSONEncoder.prettyPrinted.encode(report)
    try data.write(to: outputURL)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func currentResidentMemoryBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                rebound,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(info.resident_size)
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@main
@MainActor
enum InnoRouterPerformanceSmokeMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            guard runAggregationSelfTest() else {
                fail("Performance aggregation self-test failed.")
            }
            print("Performance aggregation self-test passed.")
            return
        }

        let samples = [
            makeSample(
                name: "navigation_replace_reset_scaling",
                smallInput: 120,
                largeInput: 240,
                threshold: 3.6,
                largeMaxMilliseconds: 200,
                measure: measureNavigationReplace
            ),
            makeSample(
                name: "modal_queue_promote_scaling",
                smallInput: 60,
                largeInput: 120,
                threshold: 3.8,
                largeMaxMilliseconds: 150,
                measure: measureModalQueue
            ),
            makeSample(
                name: "middleware_chain_scaling",
                smallInput: 4,
                largeInput: 8,
                threshold: 2.6,
                largeMaxMilliseconds: 50,
                measure: measureMiddlewareChain
            ),
            makeSample(
                name: "deep_link_pipeline_scaling",
                smallInput: 50,
                largeInput: 100,
                threshold: 3.8,
                largeMaxMilliseconds: 150,
                measure: measureDeepLinkPipeline
            ),
        ]

        let report = SmokeReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            aggregation: "median",
            measurementPairs: measurementPairCount,
            passed: samples.allSatisfy(\.passed),
            memoryFootprint: SmokeMemoryFootprint(
                residentBytes: currentResidentMemoryBytes()
            ),
            samples: samples
        )

        do {
            try writeReport(report, to: outputPath())
            if !report.passed {
                fail("Performance smoke detected a gross regression.")
            }
        } catch {
            fail("Failed to write performance smoke report: \(error)")
        }
    }
}
