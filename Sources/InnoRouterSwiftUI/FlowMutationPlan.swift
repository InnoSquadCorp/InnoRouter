import InnoRouterCore

struct FlowMutationPlan<R: Route> {
    let oldPath: [RouteStep<R>]
    let rejectionReason: FlowRejectionReason?
    let queueCoalescePolicyEligible: Bool
    let navigationJournal: NavigationExecutionJournal<R>?
    let discardedNavigationJournals: [NavigationExecutionJournal<R>]
    let modalJournals: [ModalExecutionJournal<R>]
    let discardedModalJournals: [ModalExecutionJournal<R>]
    let modalCancellationJournals: [ModalExecutionJournal<R>]

    static func rejected(
        oldPath: [RouteStep<R>],
        reason: FlowRejectionReason,
        queueCoalescePolicyEligible: Bool = false,
        navigationJournal: NavigationExecutionJournal<R>? = nil,
        discardedNavigationJournals: [NavigationExecutionJournal<R>] = [],
        modalJournals: [ModalExecutionJournal<R>] = [],
        discardedModalJournals: [ModalExecutionJournal<R>] = [],
        modalCancellationJournals: [ModalExecutionJournal<R>] = []
    ) -> Self {
        Self(
            oldPath: oldPath,
            rejectionReason: reason,
            queueCoalescePolicyEligible: queueCoalescePolicyEligible,
            navigationJournal: navigationJournal,
            discardedNavigationJournals: discardedNavigationJournals,
            modalJournals: modalJournals,
            discardedModalJournals: discardedModalJournals,
            modalCancellationJournals: modalCancellationJournals
        )
    }

    static func commit(
        oldPath: [RouteStep<R>],
        navigationJournal: NavigationExecutionJournal<R>? = nil,
        modalJournals: [ModalExecutionJournal<R>] = []
    ) -> Self {
        Self(
            oldPath: oldPath,
            rejectionReason: nil,
            queueCoalescePolicyEligible: false,
            navigationJournal: navigationJournal,
            discardedNavigationJournals: [],
            modalJournals: modalJournals,
            discardedModalJournals: [],
            modalCancellationJournals: []
        )
    }
}
