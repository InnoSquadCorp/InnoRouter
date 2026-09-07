import InnoRouterCore

enum RouterScenarioControlGraph {
    private enum RequestState: Equatable {
        case active
        case terminal
    }

    static func validate<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>
    ) throws {
        let indexedSteps = fixture.steps.enumerated().map { ($0.element.requestID, $0.offset) }
        guard Dictionary(indexedSteps, uniquingKeysWith: { first, _ in first }).count
                == fixture.steps.count else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let steps = Dictionary(uniqueKeysWithValues: indexedSteps)
        try validateStepMetadata(fixture.steps)
        try validateRequestSemantics(fixture.steps)
        try RouterScenarioRevisionValidator.validateCaptured(fixture)
        try validateControls(fixture, stepIndices: steps)
        try RouterScenarioHistoryValidator.validate(fixture, stepIndices: steps)
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

    private static func validateRequestSemantics<R: Route & Codable>(
        _ steps: [RouterScenarioStep<R>]
    ) throws {
        for step in steps {
            switch step.requestSemantics {
            case .action:
                break
            case .historyNavigation:
                guard step.context.source == .history,
                      case .apply = step.action else {
                    throw RouterScenarioReplayError.invalidEventOrdering
                }
            }
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
        case .historyNavigation: true
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

/// Replays explicit scheduling controls through production routing while
/// comparing developer-authored expectations relative to the store's revision
/// at replay start.
public enum RouterScenarioRunner {
    @MainActor
    @discardableResult
    public static func replay<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        on store: RouterTestStore<R>,
        environment: RouterScenarioReplayEnvironment? = nil
    ) async throws -> [RouterOutcome<R>] {
        let environment = environment ?? RouterScenarioReplayEnvironment(
            routeSchemaID: String(describing: R.self)
        )
        let session = try RouterScenarioReplaySession(
            fixture: fixture,
            store: store,
            environment: environment
        )
        return try await session.run()
    }
}

@MainActor
private final class RouterScenarioReplaySession<R: Route & Codable> {
    private let fixture: RouterScenarioFixture<R>
    private let store: RouterTestStore<R>
    private let stepIndices: [RouterTransitionID: Int]
    private let replayBaseline: UInt64
    private var handles: [RouterTransitionID: RouterScenarioReplayHandle<R>] = [:]
    private var outcomes: [RouterOutcome<R>?]
    private var deferralIDs: [RouterDeferralID: RouterDeferralID] = [:]
    private var activeDeferralIDs: Set<RouterDeferralID> = []
    private var completedRequestIDs: Set<RouterTransitionID> = []

    init(
        fixture: RouterScenarioFixture<R>,
        store: RouterTestStore<R>,
        environment: RouterScenarioReplayEnvironment
    ) throws {
        guard fixture.completeness.isComplete else {
            throw RouterScenarioReplayError.incomplete(fixture.completeness)
        }
        try RouterScenarioControlGraph.validate(fixture)
        let indexedSteps = fixture.steps.enumerated().map { ($0.element.requestID, $0.offset) }
        try Self.preflight(fixture.metadata, environment: environment)
        guard store.state == fixture.initialState else {
            throw RouterScenarioReplayError.initialStateMismatch
        }
        try RouterScenarioRevisionValidator.validateReplay(
            fixture,
            replayBaseline: store.revision
        )
        self.fixture = fixture
        self.store = store
        self.stepIndices = Dictionary(uniqueKeysWithValues: indexedSteps)
        self.replayBaseline = store.revision
        self.outcomes = Array(repeating: nil, count: fixture.steps.count)
    }

    func run() async throws -> [RouterOutcome<R>] {
        do {
            return try await withTaskCancellationHandler {
                try await runControls()
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelOwnedRequests()
                }
            }
        } catch {
            await cancelAndDrainOwnedWork()
            throw error
        }
    }

    private func runControls() async throws -> [RouterOutcome<R>] {
        try Task.checkCancellation()
        for control in fixture.controls.sorted(by: { $0.eventIndex < $1.eventIndex }) {
            try Task.checkCancellation()
            try await apply(control)
        }
        try Task.checkCancellation()
        guard handles.isEmpty, outcomes.allSatisfy({ $0 != nil }) else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        return outcomes.compactMap { $0 }
    }

    private func apply(_ control: RouterScenarioControl) async throws {
        switch control {
        case .submit(let requestID, _):
            try await submit(requestID)
        case .waitUntilStarted(let requestID, _):
            try await waitUntilStarted(requestID)
        case .cancel(let requestID, _):
            try cancel(requestID)
        case .advanceTime(let nanoseconds, _):
            try await advanceTime(nanoseconds)
        case .resolveDeferral(
            let requestID,
            let deferralID,
            let resolution,
            let resumeStrategy,
            _
        ):
            try resolveDeferral(
                requestID,
                deferralID: deferralID,
                resolution: resolution,
                resumeStrategy: resumeStrategy
            )
        case .awaitTerminal(let requestID, _):
            try await awaitTerminal(requestID)
        }
    }

    private func submit(_ requestID: RouterTransitionID) async throws {
        guard handles[requestID] == nil,
              !completedRequestIDs.contains(requestID),
              let stepIndex = stepIndices[requestID] else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let step = fixture.steps[stepIndex]
        let expectedRevision = try RouterScenarioRevisionValidator.translate(
            step.expectedRevision,
            captureBaseline: fixture.initialRevision,
            replayBaseline: replayBaseline,
            step: stepIndex
        )
        let request: RouterTestRequest<R> = switch step.requestSemantics {
        case .action:
            store.start(
                step.action,
                context: step.context,
                expectedRevision: expectedRevision
            )
        case .historyNavigation(let target):
            store.startHistoryNavigation(
                step.action,
                target: target,
                context: step.context,
                expectedRevision: expectedRevision
            )
        }
        handles[requestID] = handle(request)
    }

    private func waitUntilStarted(_ requestID: RouterTransitionID) async throws {
        guard let handle = handles[requestID], await handle.waitUntilStarted() else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        try Task.checkCancellation()
    }

    private func cancel(_ requestID: RouterTransitionID) throws {
        guard let handle = handles[requestID] else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        handle.cancel()
    }

    private func advanceTime(_ nanoseconds: Int64) async throws {
        guard nanoseconds >= 0, await store.waitUntilTimeIsScheduled() else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        store.advanceTime(by: .nanoseconds(nanoseconds))
    }

    private func resolveDeferral(
        _ requestID: RouterTransitionID,
        deferralID: RouterDeferralID,
        resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy
    ) throws {
        guard handles[requestID] == nil,
              !completedRequestIDs.contains(requestID),
              stepIndices[requestID] != nil else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        guard let replayDeferralID = deferralIDs[deferralID] else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        activeDeferralIDs.remove(replayDeferralID)
        handles[requestID] = handle(store.resolveDeferred(
            replayDeferralID,
            with: resolution,
            resumeStrategy: resumeStrategy
        ))
    }

    private func awaitTerminal(_ requestID: RouterTransitionID) async throws {
        guard let handle = handles[requestID],
              let stepIndex = stepIndices[requestID] else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let outcome = await handle.result()
        let actualDeferral = registerOwnedDeferral(from: outcome)
        try Task.checkCancellation()
        if let actualDeferral {
            guard let capturedID = fixture.steps[stepIndex].observedDeferralID else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
            deferralIDs[capturedID] = actualDeferral.id
        }
        try validate(outcome, stepIndex: stepIndex)
        handles.removeValue(forKey: requestID)
        completedRequestIDs.insert(requestID)
        outcomes[stepIndex] = outcome
    }

    private func cancelOwnedRequests() {
        for handle in handles.values {
            handle.cancel()
        }
    }

    private func cancelAndDrainOwnedWork() async {
        let pendingHandles = Array(handles.values)
        cancelOwnedRequests()
        for handle in pendingHandles {
            let outcome = await handle.result()
            _ = registerOwnedDeferral(from: outcome)
        }
        handles.removeAll()

        let pendingDeferrals = Array(activeDeferralIDs)
        activeDeferralIDs.removeAll()
        for deferralID in pendingDeferrals {
            let request = store.resolveDeferred(deferralID, with: .cancel)
            _ = await request.result
        }
    }

    @discardableResult
    private func registerOwnedDeferral(
        from outcome: RouterOutcome<R>
    ) -> RouterDeferredTransition? {
        guard case .deferred(_, _, _, let deferral) = outcome else { return nil }
        activeDeferralIDs.insert(deferral.id)
        return deferral
    }

    private func validate(_ outcome: RouterOutcome<R>, stepIndex: Int) throws {
        let step = fixture.steps[stepIndex]
        guard let expectation = step.expectation else {
            throw RouterScenarioReplayError.missingExpectation(step: stepIndex)
        }
        let actualState = state(of: outcome)
        guard actualState == expectation.state else {
            throw RouterScenarioReplayError.stateMismatch(step: stepIndex)
        }
        guard expectation.revision >= fixture.initialRevision else {
            throw RouterScenarioReplayError.revisionBeforeCaptureBaseline(step: stepIndex)
        }
        let expectedDelta = expectation.revision - fixture.initialRevision
        let actualRevision = revision(of: outcome)
        guard actualRevision >= replayBaseline else {
            throw RouterScenarioReplayError.revisionMismatch(
                step: stepIndex,
                expectedDelta: expectedDelta,
                actualDelta: 0
            )
        }
        let actualDelta = actualRevision - replayBaseline
        guard actualDelta == expectedDelta else {
            throw RouterScenarioReplayError.revisionMismatch(
                step: stepIndex,
                expectedDelta: expectedDelta,
                actualDelta: actualDelta
            )
        }
        let actualTerminal = RouterScenarioTerminal(outcome)
        guard actualTerminal == expectation.terminal else {
            throw RouterScenarioReplayError.terminalMismatch(
                step: stepIndex,
                expected: expectation.terminal,
                actual: actualTerminal
            )
        }
        if let expectedRejection = expectation.rejection {
            let actualRejection: RouterScenarioRejectionKind? = if case .rejected(
                _, _, _, let reason
            ) = outcome {
                RouterScenarioRejectionKind(reason)
            } else {
                nil
            }
            guard actualRejection == expectedRejection else {
                throw RouterScenarioReplayError.rejectionMismatch(
                    step: stepIndex,
                    expected: expectedRejection,
                    actual: actualRejection
                )
            }
        }
    }

    private func handle(_ request: RouterTestRequest<R>) -> RouterScenarioReplayHandle<R> {
        RouterScenarioReplayHandle(
            waitUntilStarted: { await request.waitUntilStarted() },
            cancel: { request.cancel() },
            result: { await request.result }
        )
    }

    private func state(of outcome: RouterOutcome<R>) -> RouterState<R> {
        switch outcome {
        case .applied(_, _, let after, _): after
        case .unchanged(_, let state, _),
             .deferred(_, let state, _, _),
             .rejected(_, let state, _, _): state
        }
    }

    private func revision(of outcome: RouterOutcome<R>) -> UInt64 {
        switch outcome {
        case .applied(_, _, _, let revision),
             .unchanged(_, _, let revision),
             .deferred(_, _, let revision, _),
             .rejected(_, _, let revision, _): revision
        }
    }

    private static func preflight(
        _ metadata: RouterScenarioMetadata,
        environment: RouterScenarioReplayEnvironment
    ) throws {
        guard metadata.routeSchemaID == environment.routeSchemaID else {
            throw RouterScenarioReplayError.routeSchemaMismatch(
                expected: metadata.routeSchemaID,
                actual: environment.routeSchemaID
            )
        }
        guard metadata.environmentID == environment.environmentID,
              metadata.environmentVersion == environment.environmentVersion else {
            throw RouterScenarioReplayError.environmentMismatch(
                expectedID: metadata.environmentID,
                expectedVersion: metadata.environmentVersion
            )
        }
        let available = Dictionary(
            environment.dependencies.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for requirement in metadata.dependencies {
            guard let dependency = available[requirement.id],
                  dependency.version == requirement.version else {
                throw RouterScenarioReplayError.missingDependency(
                    id: requirement.id,
                    version: requirement.version
                )
            }
            if let capability = requirement.capabilities.subtracting(
                dependency.capabilities
            ).sorted().first {
                throw RouterScenarioReplayError.missingDependencyCapability(
                    dependencyID: requirement.id,
                    capability: capability
                )
            }
        }
        if let capability = metadata.requiredCapabilities.subtracting(
            environment.capabilities
        ).sorted(by: { $0.rawValue < $1.rawValue }).first {
            throw RouterScenarioReplayError.missingReplayCapability(capability)
        }
        if let effect = metadata.externalEffectIDs.subtracting(
            environment.externalEffectIDs
        ).sorted().first {
            throw RouterScenarioReplayError.unsupportedExternalEffect(effect)
        }
    }
}
