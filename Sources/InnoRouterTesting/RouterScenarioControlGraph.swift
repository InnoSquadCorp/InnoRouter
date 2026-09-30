import InnoRouterCore

enum RouterScenarioControlGraph {
    private enum RequestState: Equatable {
        case active
        case terminal
    }

    static func validate<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>? = nil
    ) throws {
        let indexedSteps = fixture.steps.enumerated().map { ($0.element.requestID, $0.offset) }
        guard Dictionary(indexedSteps, uniquingKeysWith: { first, _ in first }).count
                == fixture.steps.count else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let steps = Dictionary(uniqueKeysWithValues: indexedSteps)
        try validateStepMetadata(fixture.steps)
        try RouterScenarioRequestSemanticsValidator.validate(fixture.steps)
        try RouterScenarioRevisionValidator.validateCaptured(fixture)
        try validateControls(fixture, stepIndices: steps)
        try RouterScenarioHistoryValidator.validate(
            fixture,
            stepIndices: steps,
            featureResolvers: featureResolvers
        )
    }

    private static func validateStepMetadata<R: Route & Codable>(
        _ steps: [RouterScenarioStep<R>]
    ) throws {
        let submissionIndices = Set(steps.map(\.submissionIndex))
        let submissionEventIndices = Set(steps.map(\.submissionEventIndex))
        guard submissionIndices == Set(steps.indices),
              submissionEventIndices.count == steps.count,
              steps.allSatisfy({
                  $0.submissionEventIndex >= 0
                      && $0.terminalEventIndex >= 0
                      && $0.submissionEventIndex < $0.terminalEventIndex
              }) else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
    }

    private static func validateControls<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        stepIndices: [RouterTransitionID: Int]
    ) throws {
        var states: [RouterTransitionID: RequestState] = [:]
        var seenEventIndices: Set<Int> = []
        var availableDeferrals: [RouterDeferralID: Int] = [:]
        var cancelledRequests: Set<RouterTransitionID> = []
        var deferralCancelledRequests: Set<RouterTransitionID> = []

        for control in fixture.controls.sorted(by: { $0.eventIndex < $1.eventIndex }) {
            guard control.eventIndex >= 0,
                  seenEventIndices.insert(control.eventIndex).inserted else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
            switch control {
            case .submit(let requestID, let eventIndex):
                guard states[requestID] == nil,
                      let stepIndex = stepIndices[requestID],
                      fixture.steps[stepIndex].submissionEventIndex == eventIndex else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
                states[requestID] = .active
            case .resolveDeferral(
                let requestID,
                let deferralID,
                let resolution,
                let resumeStrategy,
                let eventIndex
            ):
                try validateResolution(
                    requestID: requestID,
                    deferralID: deferralID,
                    resolution: resolution,
                    resumeStrategy: resumeStrategy,
                    controlEventIndex: eventIndex,
                    fixture: fixture,
                    stepIndices: stepIndices,
                    states: &states,
                    availableDeferrals: &availableDeferrals
                )
                try recordDeferralCancellation(
                    resolution,
                    requestID: requestID,
                    in: &deferralCancelledRequests
                )
            case .waitUntilStarted(let requestID, _):
                guard states[requestID] == .active else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
            case .cancel(let requestID, _):
                try recordCancellation(
                    requestID,
                    states: states,
                    cancelledRequests: &cancelledRequests
                )
            case .awaitTerminal(let requestID, let eventIndex):
                guard states[requestID] == .active,
                      let stepIndex = stepIndices[requestID],
                      fixture.steps[stepIndex].terminalEventIndex == eventIndex else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
                states[requestID] = .terminal
                let step = fixture.steps[stepIndex]
                guard (step.observedTerminal == .deferred) == (step.observedDeferralID != nil) else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
                if let deferralID = step.observedDeferralID {
                    guard availableDeferrals.updateValue(stepIndex, forKey: deferralID) == nil else {
                        throw RouterScenarioReplayError.invalidEventOrdering
                    }
                }
            case .advanceTime(let nanoseconds, _):
                guard nanoseconds >= 0 else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
            }
        }
        guard states.count == fixture.steps.count,
              states.values.allSatisfy({ $0 == .terminal }) else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        try RouterScenarioCancellationValidator.validate(
            fixture,
            cancelledRequests: cancelledRequests,
            deferralCancelledRequests: deferralCancelledRequests
        )
    }

    private static func recordCancellation(
        _ requestID: RouterTransitionID,
        states: [RouterTransitionID: RequestState],
        cancelledRequests: inout Set<RouterTransitionID>
    ) throws {
        guard states[requestID] == .active,
              cancelledRequests.insert(requestID).inserted else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
    }

    private static func recordDeferralCancellation(
        _ resolution: RouterDeferralResolution,
        requestID: RouterTransitionID,
        in requests: inout Set<RouterTransitionID>
    ) throws {
        guard resolution == .cancel else { return }
        guard requests.insert(requestID).inserted else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
    }

    private static func validateResolution<R: Route & Codable>(
        requestID: RouterTransitionID,
        deferralID: RouterDeferralID,
        resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy,
        controlEventIndex: Int,
        fixture: RouterScenarioFixture<R>,
        stepIndices: [RouterTransitionID: Int],
        states: inout [RouterTransitionID: RequestState],
        availableDeferrals: inout [RouterDeferralID: Int]
    ) throws {
        guard let stepIndex = stepIndices[requestID],
              let producerIndex = availableDeferrals.removeValue(forKey: deferralID) else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let step = fixture.steps[stepIndex]
        let producer = fixture.steps[producerIndex]
        var expectedContext = producer.context
        expectedContext.resumedDeferral = deferralID
        let hasMatchingAction: Bool = switch step.requestSemantics {
        case .action: step.action == producer.action
        case .historyNavigation, .featureAction, .featurePlan: true
        }
        guard states[requestID] == nil,
              controlEventIndex < step.submissionEventIndex,
              hasMatchingAction,
              step.context == expectedContext,
              step.requestSemantics == producer.requestSemantics else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let expectedRevision = RouterScenarioRevisionValidator.resolutionRevision(
            resolution,
            strategy: resumeStrategy,
            producerRevision: producer.observedRevision
        )
        guard step.expectedRevision == expectedRevision else {
            throw RouterScenarioReplayError.invalidExpectedRevision(step: stepIndex)
        }
        states[requestID] = .active
    }
}
