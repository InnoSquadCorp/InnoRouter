import InnoRouterCore

@MainActor
struct RouterScenarioReplayHandle<R: Route> {
    let waitUntilStarted: () async -> Bool
    let cancel: () -> Void
    let result: () async -> RouterOutcome<R>
}

enum RouterScenarioRevisionValidator {
    static func validateCaptured<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>
    ) throws {
        let rebasedRequestIDs: Set<RouterTransitionID> = Set(
            fixture.controls.compactMap { control -> RouterTransitionID? in
                guard case .resolveDeferral(
                    let requestID,
                    _,
                    .allow,
                    .rebaseOnCurrentState,
                    _
                ) = control else {
                    return nil
                }
                return requestID
            }
        )
        for (index, step) in fixture.steps.enumerated() {
            if case .historyNavigation = step.requestSemantics,
               !rebasedRequestIDs.contains(step.requestID),
               step.expectedRevision == nil {
                throw RouterScenarioReplayError.invalidExpectedRevision(step: index)
            }
            guard let revision = step.expectedRevision else { continue }
            guard revision >= fixture.initialRevision else {
                throw RouterScenarioReplayError.invalidExpectedRevision(step: index)
            }
        }
    }

    static func validateReplay<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        replayBaseline: UInt64
    ) throws {
        for (index, step) in fixture.steps.enumerated() {
            _ = try translate(
                step.expectedRevision,
                captureBaseline: fixture.initialRevision,
                replayBaseline: replayBaseline,
                step: index
            )
        }
    }

    static func translate(
        _ capturedRevision: UInt64?,
        captureBaseline: UInt64,
        replayBaseline: UInt64,
        step: Int
    ) throws -> UInt64? {
        guard let capturedRevision else { return nil }
        guard capturedRevision >= captureBaseline else {
            throw RouterScenarioReplayError.invalidExpectedRevision(step: step)
        }
        let delta = capturedRevision - captureBaseline
        let translated = replayBaseline.addingReportingOverflow(delta)
        guard !translated.overflow else {
            throw RouterScenarioReplayError.invalidExpectedRevision(step: step)
        }
        return translated.partialValue
    }

    static func resolutionRevision(
        _ resolution: RouterDeferralResolution,
        strategy: RouterDeferralResumeStrategy,
        producerRevision: UInt64
    ) -> UInt64? {
        switch (resolution, strategy) {
        case (.allow, .requireUnchangedState): producerRevision
        case (.allow, .rebaseOnCurrentState), (.reject, _), (.cancel, _): nil
        }
    }
}

enum RouterScenarioCancellationValidator {
    static func validate<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        cancelledRequests: Set<RouterTransitionID>,
        deferralCancelledRequests: Set<RouterTransitionID>
    ) throws {
        for (index, step) in fixture.steps.enumerated() {
            try validate(
                step,
                index: index,
                fixture: fixture,
                hasRequestControl: cancelledRequests.contains(step.requestID),
                hasDeferralControl: deferralCancelledRequests.contains(step.requestID)
            )
        }
    }

    private static func validate<R: Route & Codable>(
        _ step: RouterScenarioStep<R>,
        index: Int,
        fixture: RouterScenarioFixture<R>,
        hasRequestControl: Bool,
        hasDeferralControl: Bool
    ) throws {
        let hasCancelledTerminal = step.observedTerminal == .rejected
            && step.observedRejection == .cancelled
        switch step.cancellationOrigin {
        case .none:
            guard !hasRequestControl, !hasDeferralControl else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
            if hasCancelledTerminal, !isUnsupportedHistoryLifetime(step, fixture: fixture) {
                throw RouterScenarioReplayError.missingCancellationProvenance(step: index)
            }
        case .request:
            guard hasRequestControl, !hasDeferralControl, hasCancelledTerminal else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
        case .deferralDecision:
            guard !hasRequestControl, hasDeferralControl, hasCancelledTerminal else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
        }
    }

    private static func isUnsupportedHistoryLifetime<R: Route & Codable>(
        _ step: RouterScenarioStep<R>,
        fixture: RouterScenarioFixture<R>
    ) -> Bool {
        guard case .historyNavigation = step.requestSemantics,
              let control = fixture.controls.first(where: {
                  if case .resolveDeferral(let requestID, _, _, _, _) = $0 {
                      return requestID == step.requestID
                  }
                  return false
              }),
              case .resolveDeferral(_, _, .allow, _, _) = control else {
            return false
        }
        return true
    }
}
