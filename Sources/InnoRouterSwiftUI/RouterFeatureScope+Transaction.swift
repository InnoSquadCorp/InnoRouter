// MARK: - RouterFeatureScope+Transaction.swift
// InnoRouterSwiftUI - feature transactions derived from the state at execution
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterFeatureScope {
    /// Applies `steps` to this feature's subtree as the Store holds it when
    /// the request runs.
    ///
    /// A plan built when the call was made would replace the subtree with a
    /// value that predates the fire-and-forget requests made before it, and so
    /// silently revert them.
    func dispatchTransaction(
        _ steps: [RouterPlanStep<Child>],
        resourceBudget: RouterResourceBudget
    ) -> Task<RouterOutcome<Child>, Never> {
        let namespace = mapping.namespace
        let transform: RouterFeatureNodeTransform<Child> = { node in
            let builder: () -> [RouterPlanStep<Child>] = { steps }
            let plan = try RouterPlan(from: RouterState(root: node), resourceBudget: resourceBudget, builder)
            guard plan.state.windows.isEmpty, plan.state.immersiveSpace == nil else {
                throw RouterFeatureProjectionError.globalStateNotAllowed(namespace: namespace)
            }
            return plan.state.root
        }
        return startDispatch { [self] in
            await performFeaturePlan(transforming: transform, context: .init(), features: [])
        }
    }

    /// Embeds `transform` into the parent route type, so every projection in
    /// the chain is re-derived from the state at execution.
    ///
    /// Whether this feature still owns its subtree is decided there too, not
    /// when the dispatch task starts: a request queued ahead of this one can
    /// return the subtree to the feature before this one runs.
    func performFeaturePlan(
        transforming transform: @escaping RouterFeatureNodeTransform<Child>,
        context: RouterTransitionContext,
        features childFeatures: [RouterFeatureCatalogEntry]
    ) async -> RouterOutcome<Child> {
        guard let resourceBudget else {
            return projectionRejection(.routeMismatch(namespace: mapping.namespace))
        }
        let mapping = self.mapping
        let parentTransform: RouterFeatureNodeTransform<Parent> = { node in
            let current: RouterNode<Child>
            do {
                current = try mapping.projectState(from: node).root
            } catch {
                throw RouterFeatureProjectionError.routeMismatch(namespace: mapping.namespace)
            }
            let next = try transform(current)
            do {
                let state = try RouterStateDraft(root: next).build(resourceBudget: resourceBudget)
                return try mapping.embedPlanRoot(RouterPlan(state: state))
            } catch let failure as RouterResourceLimitFailure {
                throw failure
            } catch let error as RouterFeatureProjectionError {
                throw error
            } catch {
                throw RouterFeatureProjectionError.invalidFeatureState(namespace: mapping.namespace)
            }
        }
        return map(
            await parent.performFeaturePlan(
                transforming: parentTransform,
                context: context,
                features: [featureCatalogEntry] + childFeatures
            )
        )
    }
}
