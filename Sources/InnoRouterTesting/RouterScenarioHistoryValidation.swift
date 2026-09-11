import InnoRouterCore
import InnoRouterSwiftUI

private enum RouterScenarioPreparedRequest<R: Route> {
    case exact(RouterAction<R>)
    case featureExact(
        action: RouterAction<R>,
        scope: RouterScopePath,
        lifetime: RouterScenarioSceneLifetime,
        features: [RouterFeatureCatalogEntry]
    )
    case historyRebase(RouterState<R>)
    case featureRebase(
        scope: RouterScopePath,
        lifetime: RouterScenarioSceneLifetime,
        node: RouterNode<R>,
        features: [RouterFeatureCatalogEntry]
    )
}

private struct RouterScenarioDeferredProvenance<R: Route> {
    let action: RouterAction<R>
}

enum RouterScenarioHistoryValidator {
    static func validate<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        stepIndices: [RouterTransitionID: Int],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>?
    ) throws {
        var currentState = fixture.initialState
        var requests: [RouterTransitionID: RouterScenarioPreparedRequest<R>] = [:]
        var deferrals: [RouterDeferralID: RouterScenarioDeferredProvenance<R>] = [:]

        for control in fixture.controls.sorted(by: { $0.eventIndex < $1.eventIndex }) {
            switch control {
            case .submit(let requestID, _):
                try registerSubmission(
                    requestID,
                    state: currentState,
                    fixture: fixture,
                    stepIndices: stepIndices,
                    featureResolvers: featureResolvers,
                    requests: &requests
                )
            case .resolveDeferral(
                let requestID,
                let deferralID,
                let resolution,
                let resumeStrategy,
                _
            ):
                try registerResolution(
                    requestID,
                    deferralID: deferralID,
                    resolution: resolution,
                    resumeStrategy: resumeStrategy,
                    fixture: fixture,
                    stepIndices: stepIndices,
                    featureResolvers: featureResolvers,
                    requests: &requests,
                    deferrals: &deferrals
                )
            case .awaitTerminal(let requestID, _):
                try registerTerminal(
                    requestID,
                    state: &currentState,
                    fixture: fixture,
                    stepIndices: stepIndices,
                    featureResolvers: featureResolvers,
                    requests: &requests,
                    deferrals: &deferrals
                )
            case .waitUntilStarted, .cancel, .advanceTime:
                break
            }
        }
    }

    private static func registerSubmission<R: Route & Codable>(
        _ requestID: RouterTransitionID,
        state: RouterState<R>,
        fixture: RouterScenarioFixture<R>,
        stepIndices: [RouterTransitionID: Int],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>?,
        requests: inout [RouterTransitionID: RouterScenarioPreparedRequest<R>]
    ) throws {
        guard let stepIndex = stepIndices[requestID] else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let step = fixture.steps[stepIndex]
        if case .historyNavigation(let target) = step.requestSemantics {
            guard case .action(let expectedAction) = RouterHistory<R>
                .prepareNavigationMerge(target, into: state),
                  step.action == expectedAction else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
        }
        if case .featurePlan(let scope, let lifetime, let node, let features) = step.requestSemantics,
           lifetime != .expiredScene {
            guard let current = state.node(at: scope),
                  featureResolvers?.owns(current, features: features) != false,
                  case .action(let expectedAction) = prepareRouterFeaturePlan(
                node: node,
                at: scope,
                in: state
            ), step.action == expectedAction else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
        }
        switch step.requestSemantics {
        case .featureAction(let scope, let lifetime, let features):
            guard lifetime == .expiredScene || (
                state.node(at: scope).map {
                    featureResolvers?.owns($0, features: features) != false
                } == true
            ) else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
            requests[requestID] = .featureExact(
                action: step.action,
                scope: scope,
                lifetime: lifetime,
                features: features
            )
        case .featurePlan(let scope, .expiredScene, _, let features):
            requests[requestID] = .featureExact(
                action: step.action,
                scope: scope,
                lifetime: .expiredScene,
                features: features
            )
        case .action, .historyNavigation, .featurePlan:
            requests[requestID] = .exact(step.action)
        }
    }

    private static func registerResolution<R: Route & Codable>(
        _ requestID: RouterTransitionID,
        deferralID: RouterDeferralID,
        resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy,
        fixture: RouterScenarioFixture<R>,
        stepIndices: [RouterTransitionID: Int],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>?,
        requests: inout [RouterTransitionID: RouterScenarioPreparedRequest<R>],
        deferrals: inout [RouterDeferralID: RouterScenarioDeferredProvenance<R>]
    ) throws {
        guard let stepIndex = stepIndices[requestID],
              let producer = deferrals.removeValue(forKey: deferralID) else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let step = fixture.steps[stepIndex]
        guard step.action == producer.action else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        if case .historyNavigation = step.requestSemantics,
           resolution == .allow,
           step.cancellationOrigin == .none,
           step.observedTerminal == .rejected,
           step.observedRejection == .cancelled {
            throw RouterScenarioReplayError.unsupportedHistoryLifetime(step: stepIndex)
        }
        if resolution == .allow, resumeStrategy == .rebaseOnCurrentState {
            switch step.requestSemantics {
            case .historyNavigation(let target):
                requests[requestID] = .historyRebase(target)
            case .featureAction(let scope, let lifetime, let features):
                requests[requestID] = .featureExact(
                    action: producer.action,
                    scope: scope,
                    lifetime: lifetime,
                    features: features
                )
            case .featurePlan(let scope, let lifetime, let node, let features):
                if lifetime == .expiredScene {
                    requests[requestID] = .featureExact(
                        action: producer.action,
                        scope: scope,
                        lifetime: lifetime,
                        features: features
                    )
                } else {
                    requests[requestID] = .featureRebase(
                        scope: scope,
                        lifetime: lifetime,
                        node: node,
                        features: features
                    )
                }
            case .action:
                requests[requestID] = .exact(producer.action)
            }
        } else {
            if case .featureAction(let scope, let lifetime, let features) = step.requestSemantics {
                requests[requestID] = .featureExact(
                    action: producer.action,
                    scope: scope,
                    lifetime: lifetime,
                    features: features
                )
            } else {
                requests[requestID] = .exact(producer.action)
            }
        }
    }

    private static func registerTerminal<R: Route & Codable>(
        _ requestID: RouterTransitionID,
        state: inout RouterState<R>,
        fixture: RouterScenarioFixture<R>,
        stepIndices: [RouterTransitionID: Int],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>?,
        requests: inout [RouterTransitionID: RouterScenarioPreparedRequest<R>],
        deferrals: inout [RouterDeferralID: RouterScenarioDeferredProvenance<R>]
    ) throws {
        guard let stepIndex = stepIndices[requestID],
              let request = requests.removeValue(forKey: requestID) else {
            throw RouterScenarioReplayError.invalidEventOrdering
        }
        let step = fixture.steps[stepIndex]
        guard let executedAction = preparedAction(
            request,
            state: state,
            featureResolvers: featureResolvers
        ) else {
            if step.observedTerminal == .deferred {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
            state = step.observedState
            return
        }
        if step.observedTerminal == .deferred {
            guard let deferralID = step.observedDeferralID,
                  deferrals.updateValue(
                      .init(action: executedAction),
                      forKey: deferralID
                  ) == nil else {
                throw RouterScenarioReplayError.invalidEventOrdering
            }
        }
        state = step.observedState
    }

    private static func preparedAction<R: Route>(
        _ request: RouterScenarioPreparedRequest<R>,
        state: RouterState<R>,
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>?
    ) -> RouterAction<R>? {
        switch request {
        case .exact(let action):
            return action
        case .featureExact(let action, let scope, let lifetime, let features):
            guard lifetime != .expiredScene else { return nil }
            guard let current = state.node(at: scope),
                  featureResolvers?.owns(current, features: features) != false else {
                return nil
            }
            return action
        case .historyRebase(let target):
            if case .action(let action) = RouterHistory<R>
                .prepareNavigationMerge(target, into: state) {
                return action
            } else {
                return nil
            }
        case .featureRebase(let scope, let lifetime, let node, let features):
            guard lifetime != .expiredScene else { return nil }
            guard let current = state.node(at: scope),
                  featureResolvers?.owns(current, features: features) != false else {
                return nil
            }
            if case .action(let action) = prepareRouterFeaturePlan(
                node: node,
                at: scope,
                in: state
            ) {
                return action
            } else {
                return nil
            }
        }
    }
}
