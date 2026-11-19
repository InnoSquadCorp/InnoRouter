// MARK: - RouterScope+Dispatch.swift
// InnoRouterSwiftUI - immediate commits and ordered fire-and-forget dispatch
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterScope {
    func performImmediately(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        atRoot: Bool
    ) -> RouterOutcome<R>? {
        // A missing Store or an inadmissible scope is reported by the
        // asynchronous path, which already owns those outcomes. Checking the
        // Store first keeps the default timing from building a request it
        // would discard.
        guard let store, store.canCommitImmediately, resourceAdmissionRejection == nil else { return nil }
        return store.performImmediately(
            atRoot ? action : action.inScope(path),
            context: context,
            expectedRevision: expectedRevision,
            executionPrecondition: combinedExecutionPrecondition(nil)
        )
    }

    /// Applies `steps` to the state the Store holds when the request runs.
    ///
    /// A transaction is the latest in a sequence of fire-and-forget calls, so
    /// it builds on the requests made before it, including ones that have not
    /// executed yet. A plan built when the call was made would either revert
    /// those requests or be rejected as stale because of them.
    func dispatchTransaction(
        _ steps: [RouterPlanStep<R>],
        resourceBudget: RouterResourceBudget
    ) -> Task<RouterOutcome<R>, Never> {
        let path = path
        let preparation: RouterRequestPreparationBuilder<R> = { state in
            let builder: () -> [RouterPlanStep<R>] = { steps }
            do {
                return .action(.apply(try RouterPlan(from: state, resourceBudget: resourceBudget, builder)))
            } catch {
                return .rejected(routerPreparationRejection(for: error, at: path))
            }
        }
        if let store, resourceAdmissionRejection == nil, store.canCommitImmediately,
           case .action(let action) = preparation(store.state),
           let outcome = store.performImmediately(
               action, context: .init(), expectedRevision: nil,
               executionPrecondition: combinedExecutionPrecondition(nil), executionPreparation: preparation
           ) {
            return Task { outcome }
        }
        return startDispatch { [self] in
            await performRoot(preparedBy: preparation, context: .init(), executionPrecondition: nil)
        }
    }

    /// Replaces this scope's node with `transform` applied to the node the
    /// Store holds when the request runs, and again when a deferred request
    /// is rebased.
    ///
    /// A feature projection's transaction takes this path, so it builds on
    /// the requests made before it exactly as
    /// ``dispatchTransaction(_:resourceBudget:)`` does. Like that request, and
    /// unlike an exact feature plan, it reconciles scope lifetimes instead of
    /// replacing the subtree's ownership, so the requests made after it
    /// through the same scopes stay valid.
    func performFeaturePlan(
        transforming transform: @escaping RouterFeatureNodeTransform<R>,
        context: RouterTransitionContext,
        features: [RouterFeatureCatalogEntry]
    ) async -> RouterOutcome<R> {
        guard let store else { return Self.missingAuthorityOutcome() }
        if let rejection = resourceAdmissionRejection {
            return store.rejectRequest(reason: rejection, context: context)
        }
        let path = path
        let resourceBudget = store.resourceBudget
        let preparation: RouterRequestPreparationBuilder<R> = { state in
            guard let current = state.node(at: path) else {
                return .rejected(.mutation(.incompatibleNavigationTopology(path)))
            }
            do {
                return prepareRouterFeaturePlan(
                    node: try transform(current), at: path, in: state, resourceBudget: resourceBudget
                )
            } catch {
                return .rejected(routerPreparationRejection(for: error, at: path))
            }
        }
        // Only describes the request to observers; execution re-derives it.
        guard let currentNode = store.state.node(at: path) else {
            return store.rejectRequest(reason: .mutation(.incompatibleNavigationTopology(path)), context: context)
        }
        let submittedNode = (try? transform(currentNode)) ?? currentNode
        let submittedAction: RouterAction<R> = switch prepareRouterFeaturePlan(
            node: submittedNode, at: path, in: store.state, resourceBudget: resourceBudget
        ) {
        case .action(let action): action
        case .rejected: .apply(RouterPlan(state: store.state))
        }
        return await store.perform(
            submittedAction,
            context: context,
            expectedRevision: nil,
            bypassesPolicies: false,
            requestSemantics: .featurePlan(
                scope: path,
                lifetime: sceneLifetime,
                node: submittedNode,
                features: features
            ),
            executionPrecondition: combinedExecutionPrecondition(nil),
            executionPreparation: preparation,
            deferredResumePreparation: { state, _ in preparation(state) }
        )
    }

    func startDispatch<Output: Sendable>(
        _ work: @escaping @MainActor @Sendable () async -> Output
    ) -> Task<Output, Never> {
        store?.startDispatchTask(work) ?? Task { @MainActor in await work() }
    }
}
