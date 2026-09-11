// MARK: - RouterTestStore+FeatureScenario.swift
// InnoRouterTesting - feature-owned scenario submission
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore
import InnoRouterSwiftUI

@MainActor
extension RouterTestStore {
    func startFeaturePlan(
        _ action: RouterAction<R>,
        scope: RouterScopePath,
        lifetime: RouterScenarioSceneLifetime,
        node: RouterNode<R>,
        features: [RouterFeatureCatalogEntry],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) -> RouterTestRequest<R> {
        let id = underlying.reserveTransitionID()
        let requestLifetime = underlying.sceneRequestLifetime(at: scope)
        let preparation: RouterRequestPreparationBuilder<R> = { state in
            prepareRouterFeaturePlan(node: node, at: scope, in: state)
        }
        let scenePrecondition = replayScenePrecondition(lifetime, at: scope)
        let ownershipPrecondition = ownershipPrecondition(
            at: scope,
            scenePrecondition: scenePrecondition,
            features: features,
            featureResolvers: featureResolvers
        )
        let task = Task { @MainActor [underlying] in
            await underlying.perform(
                action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: false,
                startingPolicyIndex: 0,
                transitionID: id,
                requestSemantics: .featurePlan(
                    scope: scope,
                    lifetime: requestLifetime,
                    node: node,
                    features: features
                ),
                executionPrecondition: ownershipPrecondition,
                executionPreparation: preparation,
                deferredResumePreparation: { state, _ in preparation(state) }
            )
        }
        lifecycle.register(id: id, task: task)
        return RouterTestRequest(id: id, task: task, lifecycle: lifecycle)
    }

    func startFeatureAction(
        _ action: RouterAction<R>,
        scope: RouterScopePath,
        lifetime: RouterScenarioSceneLifetime,
        features: [RouterFeatureCatalogEntry],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) -> RouterTestRequest<R> {
        let id = underlying.reserveTransitionID()
        let requestLifetime = underlying.sceneRequestLifetime(at: scope)
        let scenePrecondition = replayScenePrecondition(lifetime, at: scope)
        let ownershipPrecondition = ownershipPrecondition(
            at: scope,
            scenePrecondition: scenePrecondition,
            features: features,
            featureResolvers: featureResolvers
        )
        let task = Task { @MainActor [underlying] in
            await underlying.perform(
                action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: false,
                startingPolicyIndex: 0,
                transitionID: id,
                requestSemantics: .featureAction(
                    scope: scope,
                    lifetime: requestLifetime,
                    features: features
                ),
                executionPrecondition: ownershipPrecondition
            )
        }
        lifecycle.register(id: id, task: task)
        return RouterTestRequest(id: id, task: task, lifecycle: lifecycle)
    }

    private func replayScenePrecondition(
        _ lifetime: RouterScenarioSceneLifetime,
        at scope: RouterScopePath
    ) -> RouterRequestPrecondition<R>? {
        switch lifetime {
        case .application:
            return nil
        case .currentScene:
            return underlying.sceneLifetimePrecondition(at: scope) ?? { _ in
                Self.missingReplaySceneReason(at: scope)
            }
        case .expiredScene:
            return { _ in Self.missingReplaySceneReason(at: scope) }
        }
    }

    private func ownershipPrecondition(
        at scope: RouterScopePath,
        scenePrecondition: RouterRequestPrecondition<R>?,
        features: [RouterFeatureCatalogEntry],
        featureResolvers: RouterScenarioFeatureResolverRegistry<R>
    ) -> RouterRequestPrecondition<R> {
        { state in
            if let reason = scenePrecondition?(state) { return reason }
            guard let current = state.node(at: scope),
                  featureResolvers.owns(current, features: features) else {
                let namespace = features.last?.namespace ?? "unknown"
                return .featureProjection(.routeMismatch(namespace: namespace))
            }
            return nil
        }
    }

    private static func missingReplaySceneReason(
        at scope: RouterScopePath
    ) -> RouterRejectionReason {
        switch scope.domain {
        case .application:
            return .cancelled
        case .window(let id):
            return .mutation(.windowNotFound(id))
        case .immersiveSpace(let id):
            return .mutation(.immersiveSpaceNotFound(id))
        }
    }
}
