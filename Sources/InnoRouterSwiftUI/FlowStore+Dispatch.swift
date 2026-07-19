import InnoRouterCore

// MARK: - Intent planning and dispatch

extension FlowStore {
    // `mutationPlan(for:)` and `dispatch(_:)` are `internal` rather than
    // `private` because the public entry points (`send(_:)`, `apply(_:)`)
    // live in `FlowStore+Public.swift`. Access stays inside the
    // InnoRouterSwiftUI module.
    internal func mutationPlan(for intent: FlowIntent<R>) -> FlowMutationPlan<R> {
        let context = currentMutationContext
        switch intent {
        case .push(let route):
            return dispatchPush(route, in: context)
        case .pushMany(let routes):
            return dispatchPushMany(routes, in: context)
        case .presentSheet(let route):
            return dispatchModal(step: .sheet(route), in: context)
        case .presentCover(let route):
            return dispatchModal(step: .cover(route), in: context)
        case .pop:
            return dispatchPop(in: context)
        case .popCount(let count):
            return dispatchPopCount(count, in: context)
        case .popTo(let route):
            return dispatchPopTo(route, in: context)
        case .popToRoot:
            return dispatchPopToRoot(in: context)
        case .dismiss:
            return dispatchDismiss(in: context)
        case .dismissAll:
            return dispatchDismissAll(in: context)
        case .reset(let steps):
            return dispatchReset(steps, in: context)
        case .replaceStack(let routes):
            return dispatchReplaceStack(routes, in: context)
        case .backOrPush(let route):
            return dispatchBackOrPush(route, in: context)
        case .pushUniqueRoot(let route):
            return dispatchPushUniqueRoot(route, in: context)
        case .backOrPushDismissingModal(let route):
            return dispatchDismissingModal(in: context) { updatedContext in
                self.dispatchBackOrPush(route, in: updatedContext)
            }
        case .pushUniqueRootDismissingModal(let route):
            return dispatchDismissingModal(in: context) { updatedContext in
                self.dispatchPushUniqueRoot(route, in: updatedContext)
            }
        }
    }

    private func dispatchPush(_ route: R, in context: FlowMutationContext) -> FlowMutationPlan<R> {
        if context.projection.currentPresentation != nil {
            return .rejected(
                oldPath: path,
                reason: .pushBlockedByModalTail,
                diagnosticContext: Self.flowInvariantDiagnostic("push-blocked-by-modal-tail")
            )
        }
        return dispatchNavigation(.push(route), in: context)
    }

    private func dispatchPushMany(
        _ routes: [R],
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        let command: NavigationCommand<R>
        switch routes.count {
        case 0:
            return .commit(oldPath: path)
        case 1:
            command = .push(routes[0])
        default:
            command = .pushAll(routes)
        }
        if context.projection.currentPresentation != nil {
            return .rejected(
                oldPath: path,
                reason: .pushBlockedByModalTail,
                diagnosticContext: Self.flowInvariantDiagnostic("push-blocked-by-modal-tail")
            )
        }
        return dispatchNavigation(command, in: context)
    }

    private func dispatchModal(
        step: RouteStep<R>,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        let journal = modalStore.previewFlowCommand(
            .present(Self.presentation(for: step)),
            from: context.modalState
        )

        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                diagnosticContext: Self.rejectionDiagnosticContext(from: reason),
                modalCancellationJournals: [journal]
            )
        }

        return .commit(oldPath: path, modalJournals: [journal])
    }

    private func dispatchPop(in context: FlowMutationContext) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation == nil else { return .commit(oldPath: path) }
        return dispatchNavigation(.pop, in: context)
    }

    private func dispatchPopCount(
        _ count: Int,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation == nil else { return .commit(oldPath: path) }
        let command: NavigationCommand<R> = count > 0 && count == context.navigationState.path.count
            ? .popToRoot
            : .popCount(count)
        return dispatchNavigation(command, in: context)
    }

    private func dispatchPopTo(
        _ route: R,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation == nil else { return .commit(oldPath: path) }
        return dispatchNavigation(.popTo(route), in: context)
    }

    private func dispatchPopToRoot(in context: FlowMutationContext) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation == nil else { return .commit(oldPath: path) }
        return dispatchNavigation(.popToRoot, in: context)
    }

    private func dispatchNavigation(
        _ command: NavigationCommand<R>,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        let journal = navigationStore.previewFlowCommand(command, from: context.navigationState)
        if !journal.result.isSuccess {
            return rejectedNavigationPreview(journal, queueCoalescePolicyEligible: true)
        }

        return .commit(oldPath: path, navigationJournal: journal)
    }

    private func dispatchDismiss(in context: FlowMutationContext) -> FlowMutationPlan<R> {
        let journal = modalStore.previewFlowCommand(
            .dismissCurrent(reason: .dismiss),
            from: context.modalState
        )
        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                diagnosticContext: Self.rejectionDiagnosticContext(from: reason),
                modalCancellationJournals: [journal]
            )
        }

        return .commit(oldPath: path, modalJournals: [journal])
    }

    private func dispatchDismissAll(in context: FlowMutationContext) -> FlowMutationPlan<R> {
        let journal = modalStore.previewFlowCommand(
            .dismissAll,
            from: context.modalState
        )
        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                diagnosticContext: Self.rejectionDiagnosticContext(from: reason),
                modalCancellationJournals: [journal]
            )
        }

        return .commit(oldPath: path, modalJournals: [journal])
    }

    @discardableResult
    private func dispatchReset(
        _ steps: [RouteStep<R>],
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        do {
            try FlowPlan<R>.validate(steps)
        } catch {
            return .rejected(
                oldPath: path,
                reason: .invalidResetPath,
                diagnosticContext: Self.flowInvariantDiagnostic("invalid-reset-path")
            )
        }

        let (pushRoutes, modalTail) = Self.decompose(steps)

        let navJournal = navigationStore.previewFlowCommand(
            .replace(pushRoutes),
            from: context.navigationState
        )
        if !navJournal.result.isSuccess {
            return rejectedNavigationPreview(navJournal, queueCoalescePolicyEligible: true)
        }

        let modalPlan = previewModalReset(to: modalTail, from: context.modalState)
        switch modalPlan {
        case .rejected(let reason, let discardedJournals, let cancellationJournal):
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                diagnosticContext: Self.rejectionDiagnosticContext(from: reason),
                discardedNavigationJournals: [navJournal],
                discardedModalJournals: discardedJournals,
                modalCancellationJournals: [cancellationJournal]
            )
        case .commit(let modalJournals):
            return .commit(
                oldPath: path,
                navigationJournal: navJournal,
                modalJournals: modalJournals
            )
        }
    }

    /// Replaces the navigation push prefix with `routes`, dropping any
    /// active modal tail. Routes through `dispatchReset` so the same
    /// invariant validation + middleware pipeline applies.
    private func dispatchReplaceStack(
        _ routes: [R],
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        let steps = routes.map(RouteStep<R>.push)
        return dispatchReset(steps, in: context)
    }

    /// Pops the navigation stack back to `route` if it's already in the
    /// stack. Otherwise falls through to `dispatchPush`, which honours
    /// the modal-tail invariant by rejecting with
    /// `.pushBlockedByModalTail` when a modal is active.
    private func dispatchBackOrPush(
        _ route: R,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        if context.projection.currentPresentation != nil {
            return .rejected(
                oldPath: path,
                reason: .pushBlockedByModalTail,
                diagnosticContext: Self.flowInvariantDiagnostic("push-blocked-by-modal-tail")
            )
        }

        if context.navigationState.path.contains(route) {
            let journal = navigationStore.previewFlowCommand(.popTo(route), from: context.navigationState)
            if !journal.result.isSuccess {
                return rejectedNavigationPreview(journal, queueCoalescePolicyEligible: true)
            }
            return .commit(oldPath: path, navigationJournal: journal)
        }
        return dispatchPush(route, in: context)
    }

    private func rejectedNavigationPreview(
        _ journal: NavigationExecutionJournal<R>,
        queueCoalescePolicyEligible: Bool
    ) -> FlowMutationPlan<R> {
        let reason: FlowRejectionReason
        if case .cancelled(let cancellation) = journal.result {
            reason = .middlewareRejected(debugName: Self.debugName(from: cancellation))
        } else {
            // Keep the 5.x public rejection enum source-compatible. A nil
            // participant identifies an engine-level execution refusal.
            reason = .middlewareRejected(debugName: nil)
        }

        if journal.stateAfter == journal.stateBefore {
            return .rejected(
                oldPath: path,
                reason: reason,
                diagnosticContext: Self.rejectionDiagnosticContext(from: journal.result),
                queueCoalescePolicyEligible: queueCoalescePolicyEligible,
                navigationJournal: journal
            )
        }

        return .rejected(
            oldPath: path,
            reason: reason,
            diagnosticContext: Self.rejectionDiagnosticContext(from: journal.result),
            queueCoalescePolicyEligible: queueCoalescePolicyEligible,
            discardedNavigationJournals: [journal]
        )
    }

    /// Silent no-op when the navigation stack already contains `route`.
    /// Otherwise dispatches as `.push(route)`, so a modal tail rejects
    /// the intent with `.pushBlockedByModalTail`.
    private func dispatchPushUniqueRoot(
        _ route: R,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        if context.navigationState.path.contains(route) {
            return .commit(oldPath: path)
        }
        return dispatchPush(route, in: context)
    }

    /// Dismisses any active modal tail and then runs `inner`. If
    /// the dismiss is cancelled by middleware, the outer intent is
    /// rejected and `inner` does NOT run. If no modal is active,
    /// `inner` runs directly. Promoting a queued modal does not count
    /// as a successful dismissal for these intents; they only proceed
    /// once the modal tail is fully gone, otherwise the outer intent
    /// is rejected with `.pushBlockedByModalTail`.
    private func dispatchDismissingModal(
        in context: FlowMutationContext,
        inner: (FlowMutationContext) -> FlowMutationPlan<R>
    ) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation != nil else {
            return inner(context)
        }
        let dismissPlan = dispatchDismiss(in: context)
        if dismissPlan.rejectionReason != nil {
            return dismissPlan
        }
        let promotedPresentation = dismissPlan.modalJournals.last?.stateAfter.currentPresentation
        guard promotedPresentation == nil else {
            return FlowMutationPlan(
                oldPath: path,
                rejectionReason: .pushBlockedByModalTail,
                rejectionDiagnosticContext: Self.flowInvariantDiagnostic("push-blocked-by-promoted-modal"),
                queueCoalescePolicyEligible: false,
                navigationJournal: nil,
                discardedNavigationJournals: [],
                modalJournals: dismissPlan.modalJournals,
                discardedModalJournals: dismissPlan.discardedModalJournals,
                modalCancellationJournals: dismissPlan.modalCancellationJournals
            )
        }

        let updatedContext = FlowMutationContext(
            navigationState: context.navigationState,
            modalState: dismissPlan.modalJournals.last?.stateAfter ?? context.modalState
        )
        let innerPlan = inner(updatedContext)
        return FlowMutationPlan(
            oldPath: path,
            rejectionReason: innerPlan.rejectionReason,
            rejectionDiagnosticContext: innerPlan.rejectionDiagnosticContext,
            queueCoalescePolicyEligible: innerPlan.queueCoalescePolicyEligible,
            navigationJournal: innerPlan.navigationJournal,
            discardedNavigationJournals: innerPlan.discardedNavigationJournals,
            modalJournals: dismissPlan.modalJournals + innerPlan.modalJournals,
            discardedModalJournals: dismissPlan.discardedModalJournals
                + innerPlan.discardedModalJournals,
            modalCancellationJournals: dismissPlan.modalCancellationJournals
                + innerPlan.modalCancellationJournals
        )
    }
}
