import Foundation
import Observation

public enum RouterInspectorScenarioStatus: String, Hashable, Sendable {
    case idle
    case recording
    case complete
    case incomplete
    case cancelled
    case failed
}

/// Stable, payload-free failure categories suitable for UI and telemetry.
public enum RouterInspectorScenarioFailure: String, Hashable, Sendable {
    case startFailed
    case stopFailed
    case importFailed

    var localizationKey: String {
        switch self {
        case .startFailed: "Scenario recording could not start"
        case .stopFailed: "Scenario recording could not stop"
        case .importFailed: "Scenario import failed"
        }
    }
}

public struct RouterInspectorScenarioStopResult: Hashable, Sendable {
    public let status: RouterInspectorScenarioStatus
    public let capturedStepCount: Int
    public let summary: String
    public let rawFixtureData: Data?

    public init(
        status: RouterInspectorScenarioStatus,
        capturedStepCount: Int,
        summary: String,
        rawFixtureData: Data? = nil
    ) {
        self.status = status
        self.capturedStepCount = capturedStepCount
        self.summary = summary
        self.rawFixtureData = rawFixtureData
    }
}

/// Payload-free Inspector state with opt-in commands supplied at the app's
/// assembly boundary. `InnoRouterTesting` provides the standard recorder
/// adapter; apps that do not import it pay no runtime dependency cost.
@MainActor
@Observable
public final class RouterInspectorScenarioController {
    public private(set) var status: RouterInspectorScenarioStatus = .idle
    public private(set) var capturedStepCount = 0
    public private(set) var summary = ""
    public private(set) var failure: RouterInspectorScenarioFailure?
    public let capacity: Int

    @ObservationIgnored private let startRecording: @MainActor () throws -> Void
    @ObservationIgnored private let stopRecording: @MainActor () throws -> RouterInspectorScenarioStopResult
    @ObservationIgnored private let currentStepCount: @MainActor () -> Int
    @ObservationIgnored private let importFixture: (@MainActor (Data) throws -> RouterInspectorScenarioStopResult)?
    @ObservationIgnored private var rawFixtureData: Data?

    public init(
        capacity: Int,
        start: @escaping @MainActor () throws -> Void,
        stop: @escaping @MainActor () throws -> RouterInspectorScenarioStopResult,
        currentStepCount: @escaping @MainActor () -> Int,
        importFixture: (@MainActor (Data) throws -> RouterInspectorScenarioStopResult)? = nil
    ) {
        self.capacity = max(1, capacity)
        self.startRecording = start
        self.stopRecording = stop
        self.currentStepCount = currentStepCount
        self.importFixture = importFixture
    }

    public func start() {
        guard status != .recording else { return }
        do {
            try startRecording()
            rawFixtureData = nil
            capturedStepCount = 0
            summary = ""
            failure = nil
            status = .recording
        } catch {
            fail(.startFailed, summary: "Scenario recording could not start")
        }
    }

    public func refreshProgress() {
        guard status == .recording else { return }
        capturedStepCount = min(capacity, max(0, currentStepCount()))
    }

    public func stop() {
        guard status == .recording else { return }
        do {
            let result = try stopRecording()
            capturedStepCount = result.capturedStepCount
            summary = result.summary
            rawFixtureData = result.rawFixtureData
            failure = nil
            status = result.status
        } catch {
            fail(.stopFailed, summary: "Scenario recording could not stop")
        }
    }

    public func cancel() {
        guard status == .recording else { return }
        _ = try? stopRecording()
        rawFixtureData = nil
        summary = ""
        failure = nil
        status = .cancelled
    }

    /// Raw fixtures may contain application route payloads. Callers and the
    /// UI must present this as an explicit, non-redacted export.
    public func rawExportData() -> Data? {
        rawFixtureData
    }

    public var canImportRawFixture: Bool { importFixture != nil }

    public func importRawFixture(_ data: Data) {
        guard status != .recording, let importFixture else { return }
        do {
            let result = try importFixture(data)
            capturedStepCount = result.capturedStepCount
            summary = result.summary
            rawFixtureData = result.rawFixtureData ?? data
            failure = nil
            status = result.status
        } catch {
            fail(.importFailed, summary: "Scenario import failed")
        }
    }

    private func fail(_ failure: RouterInspectorScenarioFailure, summary key: String) {
        rawFixtureData = nil
        capturedStepCount = 0
        summary = routerInspectorLocalized(key)
        self.failure = failure
        status = .failed
    }
}
