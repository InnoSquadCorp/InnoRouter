import Foundation

import InnoRouterCore

public struct RouterScenarioFixture<R: Route & Codable>: Hashable, Sendable, Codable {
    public let formatVersion: Int
    public let initialState: RouterState<R>
    public let initialRevision: UInt64
    public let metadata: RouterScenarioMetadata
    public let steps: [RouterScenarioStep<R>]
    public let controls: [RouterScenarioControl]
    public let completeness: RouterScenarioCompleteness

    public init(
        initialState: RouterState<R>,
        initialRevision: UInt64 = 0,
        metadata: RouterScenarioMetadata? = nil,
        steps: [RouterScenarioStep<R>],
        controls: [RouterScenarioControl]? = nil,
        completeness: RouterScenarioCompleteness = .init()
    ) {
        self.formatVersion = 5
        self.initialState = initialState
        self.initialRevision = initialRevision
        self.metadata = metadata ?? RouterScenarioMetadata(
            routeSchemaID: String(describing: R.self)
        )
        self.steps = steps
        self.controls = controls ?? steps.flatMap { step in
            [
                .submit(requestID: step.requestID, eventIndex: step.submissionEventIndex),
                .awaitTerminal(requestID: step.requestID, eventIndex: step.terminalEventIndex),
            ]
        }
        self.completeness = .init(
            unpairedRequestCount: completeness.unpairedRequestCount,
            droppedStepCount: completeness.droppedStepCount,
            missingExpectationCount: max(
                completeness.missingExpectationCount,
                steps.reduce(into: 0) { if $1.expectation == nil { $0 += 1 } }
            ),
            missingControlCount: completeness.missingControlCount
        )
    }

    /// Returns a fixture with explicit developer-authored expectations.
    public func settingExpectations(
        _ expectations: [RouterScenarioExpectation<R>]
    ) throws -> Self {
        guard expectations.count == steps.count else {
            throw RouterScenarioFixtureError.expectationCountMismatch(
                expected: steps.count,
                actual: expectations.count
            )
        }
        let expectedSteps = zip(steps, expectations).map { step, expectation in
            RouterScenarioStep(
                requestID: step.requestID,
                submissionIndex: step.submissionIndex,
                submissionEventIndex: step.submissionEventIndex,
                terminalEventIndex: step.terminalEventIndex,
                action: step.action,
                context: step.context,
                requestSemantics: step.requestSemantics,
                expectedRevision: step.expectedRevision,
                cancellationOrigin: step.cancellationOrigin,
                observedState: step.observedState,
                observedRevision: step.observedRevision,
                observedTerminal: step.observedTerminal,
                observedRejection: step.observedRejection,
                observedDeferralID: step.observedDeferralID,
                expectation: expectation
            )
        }
        return .init(
            initialState: initialState,
            initialRevision: initialRevision,
            metadata: metadata,
            steps: expectedSteps,
            controls: controls,
            completeness: .init(
                unpairedRequestCount: completeness.unpairedRequestCount,
                droppedStepCount: completeness.droppedStepCount,
                missingExpectationCount: 0,
                missingControlCount: completeness.missingControlCount
            )
        )
    }

    /// Decodes a fixture only after bounded-size checks and validates its
    /// format and step count before replay.
    public static func decode(
        from data: Data,
        maximumByteCount: Int = 2 * 1_024 * 1_024,
        maximumStepCount: Int = 2_000
    ) throws -> Self {
        guard data.count <= max(1, maximumByteCount) else {
            throw RouterScenarioFixtureError.encodedDataTooLarge(
                actual: data.count,
                maximum: max(1, maximumByteCount)
            )
        }
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        guard fixture.steps.count <= max(1, maximumStepCount) else {
            throw RouterScenarioFixtureError.tooManySteps(
                actual: fixture.steps.count,
                maximum: max(1, maximumStepCount)
            )
        }
        return fixture
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case initialState
        case initialRevision
        case metadata
        case steps
        case controls
        case completeness
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == 5 else {
            throw RouterScenarioFixtureError.unsupportedFormatVersion(formatVersion)
        }
        let initialState = try container.decode(RouterState<R>.self, forKey: .initialState)
        let initialRevision = try container.decode(UInt64.self, forKey: .initialRevision)
        let metadata = try container.decode(RouterScenarioMetadata.self, forKey: .metadata)
        let steps = try container.decode([RouterScenarioStep<R>].self, forKey: .steps)
        let controls = try container.decode([RouterScenarioControl].self, forKey: .controls)
        let completeness = try container.decode(
            RouterScenarioCompleteness.self,
            forKey: .completeness
        )
        self.init(
            initialState: initialState,
            initialRevision: initialRevision,
            metadata: metadata,
            steps: steps,
            controls: controls,
            completeness: completeness
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(initialState, forKey: .initialState)
        try container.encode(initialRevision, forKey: .initialRevision)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(steps, forKey: .steps)
        try container.encode(controls, forKey: .controls)
        try container.encode(completeness, forKey: .completeness)
    }
}

public enum RouterScenarioFixtureError: Error, Hashable, Sendable {
    case expectationCountMismatch(expected: Int, actual: Int)
    case unsupportedFormatVersion(Int)
    case encodedDataTooLarge(actual: Int, maximum: Int)
    case tooManySteps(actual: Int, maximum: Int)
}
