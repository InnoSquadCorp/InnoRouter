import Foundation

import InnoRouterCore

@MainActor
extension RouterStore {
    /// One runtime waiter path for navigation and transient presentations.
    func awaitPresentation<Value: Sendable>(
        _ action: RouterAction<R>,
        id: UUID,
        at path: RouterScopePath,
        expecting _: Value.Type,
        selectionActions: [RouterPresentationAction<Value>]?,
        executionPrecondition: RouterRequestPrecondition<R>?,
        requestSemantics: RouterRequestSemantics<R>
    ) async -> RouterPresentationOutcome<Value> {
        // Admit caller-owned metadata before hashing a scope or invoking an
        // application authorization callback. This has no lasting reservation.
        let scopedAction: RouterAction<R>
        do {
            try resourceBudget.validateReplacement(RouterNode<R>.stack(), at: path)
            try resourceBudget.validateInput(action)
            scopedAction = action.inScope(path)
            try resourceBudget.validateInput(scopedAction)
        } catch {
            return .rejected(.resourceLimit(error))
        }
        // Candidate-state admission belongs to serialized execution: earlier
        // queued work may free capacity before this show runs. Waiter setup is
        // bounded by the same request queue and never commits candidate state.
        let transitionID = reserveTransitionID()
        let waiter = RouterPresentationWaiter<Value>()
        let ownerLifetime = scopeLifetimePrecondition(at: path)
        let capturedAuthorization = authorizationPrecondition(request: nil, existing: { state in
            ownerLifetime(state) ?? executionPrecondition?(state)
        })
        let resultPrecondition: @MainActor @Sendable () -> RouterRejectionReason? = { [weak self] in
            guard let self else { return .cancelled }
            guard let token = waiter.activatedPresentationToken,
                  self.presentationLifetimes[id]?.token == token else {
                return .mutation(.expiredPresentation(id, scope: path))
            }
            return capturedAuthorization?(self.state)
        }
        let prepareAction: ((RouterPresentationActionID, RouterPresentationCompletionOwner) -> RouterPresentationValuePreparation)? = selectionActions.map { actions in
            { actionID, owner in
                guard let selected = actions.first(where: { $0.descriptor.id == actionID }) else { return .typeMismatch }
                return waiter.prepare(selected.value, owner: owner, actionID: actionID)
            }
        }
        let erased = AnyRouterPresentationWaiter(
            ownerPath: path,
            showRequestRootID: transitionID,
            activatedToken: { waiter.activatedPresentationToken },
            activate: { waiter.activatedPresentationToken = $0 },
            prepareValue: { value, owner in
                guard let value = value as? Value else { return .typeMismatch }
                return waiter.prepare(value, owner: owner)
            },
            prepareAction: prepareAction,
            resultPrecondition: resultPrecondition,
            movePreparedValue: { waiter.movePreparedValue(from: $0, to: $1) },
            clearPreparedValue: { waiter.clearPreparedValue(ownedBy: $0) },
            finishAfterDismissal: { waiter.finishAfterDismissal(ownedBy: $0) },
            finishCancelled: { waiter.finish(.cancelled) },
            finishRejected: { waiter.finish(.rejected($0)) },
            lifetimeIsCurrent: { [weak self] in
                guard let self else { return false }
                return ownerLifetime(self.state) == nil
            }
        )
        presentationWaiters[id] = erased
        let identity = erased.identity
        let pending: RouterRequestPrecondition<R> = { [weak self] state in
            guard let self, self.presentationWaiters[id]?.identity == identity else { return .cancelled }
            return capturedAuthorization?(state)
        }
        registerPresentationRequest(id, transitionID: transitionID)
        return await withTaskCancellationHandler {
            let outcome = await perform(
                scopedAction, context: .init(), expectedRevision: nil, bypassesPolicies: false,
                transitionID: transitionID, requestSemantics: requestSemantics,
                executionPrecondition: pending
            )
            unregisterPresentationRequest(id, transitionID: transitionID)
            switch outcome {
            case .applied, .deferred: break
            case .unchanged:
                if presentationWaiters[id]?.identity == identity { presentationWaiters.removeValue(forKey: id) }
                waiter.finish(.dismissed)
            case .rejected(_, _, _, let reason):
                if presentationWaiters[id]?.identity == identity { presentationWaiters.removeValue(forKey: id) }
                waiter.finish(reason == .cancelled && Task.isCancelled ? .cancelled : .rejected(reason))
            }
            return await waiter.wait()
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelPresentation(id: id, at: path, waiterIdentity: identity)
            }
        }
    }
}

@MainActor
extension RouterStore {
    func pendingPresentationConflict(
        in proposed: RouterState<R>, requestRootID: RouterTransitionID
    ) -> UUID? {
        guard presentationWaiters.values.contains(where: {
            $0.activatedToken() == nil && $0.showRequestRootID != requestRootID
        }) else { return nil }
        var nodes = [proposed.root] + proposed.windows.map(\.node)
        if let space = proposed.immersiveSpace { nodes.append(space.node) }
        while let node = nodes.popLast() {
            switch node {
            case .container(let container): nodes += container.branches.map(\.node)
            case .stack(let stack):
                guard let family = stack.presentationFamily else { continue }
                if let waiter = presentationWaiters[family.id], waiter.activatedToken() == nil,
                   waiter.showRequestRootID != requestRootID { return family.id }
                if case .navigation(let navigation) = family { nodes.append(navigation.node) }
            }
        }
        return nil
    }
}
