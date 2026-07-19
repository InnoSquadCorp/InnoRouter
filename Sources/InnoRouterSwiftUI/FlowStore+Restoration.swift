import InnoRouterCore

@MainActor
enum FlowRestorationApplyResult<R: Route> {
    case restored
    case rejected(FlowRejectionReason)
    case stateMismatch(actualPath: [RouteStep<R>])
}

@MainActor
extension FlowStore {
    /// Previews a persisted plan and commits it only when middleware leaves
    /// the requested path unchanged.
    func restorePlanAtomically(_ plan: FlowPlan<R>) -> FlowRestorationApplyResult<R> {
        if let rejection = rejectReentrantApplyIfNeeded(plan) {
            guard case .rejected(_, let reason) = rejection else {
                preconditionFailure("A reentrant Flow apply must be rejected.")
            }
            return .rejected(reason)
        }

        return withFlowMutationBoundary {
            let intent = FlowIntent<R>.reset(plan.steps)
            let mutationPlan = mutationPlan(for: intent)

            if let reason = mutationPlan.rejectionReason {
                _ = applyWithinFlowMutationBoundary(mutationPlan, intent: intent)
                return .rejected(reason)
            }

            let context = currentMutationContext
            let navigationState = mutationPlan.navigationJournal?.stateAfter
                ?? context.navigationState
            let modalState = mutationPlan.modalJournals.last?.stateAfter
                ?? context.modalState
            let projectedPath = FlowMutationContext(
                navigationState: navigationState,
                modalState: modalState
            ).projection.path

            guard projectedPath == plan.steps else {
                discardRestorationPreview(mutationPlan)
                return .stateMismatch(actualPath: projectedPath)
            }

            _ = applyWithinFlowMutationBoundary(mutationPlan, intent: intent)
            return .restored
        }
    }

    private func discardRestorationPreview(_ plan: FlowMutationPlan<R>) {
        withInternalMutation {
            if let journal = plan.navigationJournal {
                navigationStore.discardFlowPreview(journal)
            }
            for journal in plan.discardedNavigationJournals {
                navigationStore.discardFlowPreview(journal)
            }
            for journal in plan.modalJournals + plan.discardedModalJournals
                + plan.modalCancellationJournals {
                modalStore.discardFlowPreview(journal)
            }
        }
    }
}
