import InnoRouterCore

/// Replays explicit scheduling controls through production routing while
/// comparing developer-authored expectations relative to the store's revision
/// at replay start.
public enum RouterScenarioRunner {
    @MainActor
    @discardableResult
    public static func replay<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        on store: RouterTestStore<R>,
        environment: RouterScenarioReplayEnvironment? = nil,
        featureResolvers: [RouterScenarioFeatureResolver<R>] = []
    ) async throws -> [RouterOutcome<R>] {
        let environment = environment ?? RouterScenarioReplayEnvironment(
            routeSchemaID: String(describing: R.self)
        )
        let session = try RouterScenarioReplaySession(
            fixture: fixture,
            store: store,
            environment: environment,
            featureResolvers: featureResolvers
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
    private let featureResolvers: RouterScenarioFeatureResolverRegistry<R>
    private var handles: [RouterTransitionID: RouterScenarioReplayHandle<R>] = [:]
    private var outcomes: [RouterOutcome<R>?]
    private var deferralIDs: [RouterDeferralID: RouterDeferralID] = [:]
    private var activeDeferralIDs: Set<RouterDeferralID> = []
    private var completedRequestIDs: Set<RouterTransitionID> = []

    init(
        fixture: RouterScenarioFixture<R>,
        store: RouterTestStore<R>,
        environment: RouterScenarioReplayEnvironment,
        featureResolvers: [RouterScenarioFeatureResolver<R>]
    ) throws {
        guard fixture.completeness.isComplete else {
            throw RouterScenarioReplayError.incomplete(fixture.completeness)
        }
        let featureResolvers = try RouterScenarioFeatureResolverRegistry(featureResolvers)
        for step in fixture.steps {
            switch step.requestSemantics {
            case .featureAction(_, _, let features),
                 .featurePlan(_, _, _, let features):
                try featureResolvers.require(features)
            case .action, .historyNavigation:
                break
            }
        }
        try RouterScenarioControlGraph.validate(
            fixture,
            featureResolvers: featureResolvers
        )
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
        self.featureResolvers = featureResolvers
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
        case .featureAction(let scope, let lifetime, let features):
            store.startFeatureAction(
                step.action,
                scope: scope,
                lifetime: lifetime,
                features: features,
                featureResolvers: featureResolvers,
                context: step.context,
                expectedRevision: expectedRevision
            )
        case .featurePlan(let scope, let lifetime, let node, let features):
            store.startFeaturePlan(
                step.action,
                scope: scope,
                lifetime: lifetime,
                node: node,
                features: features,
                featureResolvers: featureResolvers,
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
