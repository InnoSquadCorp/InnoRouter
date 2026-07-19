import InnoRouterCore

@MainActor
extension FlowStore {
    /// Plans and commits one intent inside the same mutation boundary.
    ///
    /// Middleware runs while `mutationPlan(for:)` is built. Keeping planning
    /// inside this boundary ensures a middleware that synchronously calls
    /// `send(_:)` cannot commit against the same pre-mutation snapshot and be
    /// overwritten by the outer preview. Those nested sends are queued by
    /// `deferReentrantIntentIfNeeded(_:)` and drain FIFO after this complete
    /// plan has committed and delivered its events.
    @discardableResult
    internal func dispatch(_ intent: FlowIntent<R>) -> FlowPlanApplyResult<R> {
        withFlowMutationBoundary {
            applyWithinFlowMutationBoundary(mutationPlan(for: intent), intent: intent)
        }
    }

    internal func applyWithinFlowMutationBoundary(
        _ plan: FlowMutationPlan<R>,
        intent: FlowIntent<R>
    ) -> FlowPlanApplyResult<R> {
        let handlesInnerLifecycle = plan.navigationJournal != nil
            || !plan.discardedNavigationJournals.isEmpty
            || !plan.modalJournals.isEmpty
            || !plan.discardedModalJournals.isEmpty
            || !plan.modalCancellationJournals.isEmpty
        if handlesInnerLifecycle {
            beginBufferingInnerEvents(from: plan.oldPath)
        }

        if handlesInnerLifecycle {
            withInternalMutation {
                for journal in plan.discardedNavigationJournals {
                    navigationStore.discardFlowPreview(journal)
                }
                if let navigationJournal = plan.navigationJournal {
                    _ = navigationStore.commitFlowPreview(navigationJournal)
                }
                for journal in plan.discardedModalJournals {
                    modalStore.discardFlowPreview(journal)
                }
                modalStore.commitFlowPreviews(plan.modalJournals)
                for journal in plan.modalCancellationJournals {
                    _ = modalStore.commitFlowCancellation(journal)
                }
            }
        }

        if handlesInnerLifecycle {
            syncPathFromStoresWithoutEmitting()
            finishBufferingInnerEvents()
        } else {
            syncPathFromStores(from: plan.oldPath)
        }

        if let rejectionReason = plan.rejectionReason {
            emitIntentRejected(
                intent,
                reason: rejectionReason,
                applyQueueCoalescePolicy: plan.queueCoalescePolicyEligible
            )
            return .rejected(currentPath: path, reason: rejectionReason)
        }

        return .applied(path: path)
    }
}
