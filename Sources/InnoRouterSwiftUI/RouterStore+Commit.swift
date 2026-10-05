import Foundation

import InnoRouterCore

@MainActor
extension RouterStore {
    func commitPreparedTransition(
        _ transition: RouterTransition<R>,
        requestRootID: RouterTransitionID,
        presentationCompletionOwner: RouterPresentationCompletionOwner,
        lifetimeMutation: RouterScopeLifetimeMutation,
        hostReplacement: RouterHostReplacement<R>?,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) -> RouterOutcome<R> {
        guard revision == transition.initialRevision else {
            return reject(
                transition.id,
                reason: .staleState(
                    expectedRevision: transition.initialRevision,
                    actualRevision: revision
                ),
                context: transition.context,
                action: transition.action
            )
        }
        guard !requestCancellationIsPending(transition.id) else {
            return reject(
                transition.id,
                reason: .cancelled,
                context: transition.context,
                action: transition.action
            )
        }
        if let rejection = executionPrecondition?(state) {
            return reject(
                transition.id,
                reason: rejection,
                context: transition.context,
                action: transition.action
            )
        }
        guard !requestCancellationIsPending(transition.id) else {
            return reject(
                transition.id,
                reason: .cancelled,
                context: transition.context,
                action: transition.action
            )
        }

        do {
            try (hostReplacement?.descriptor ?? hostDescriptor)?.validate(
                transition.proposedState, resourceBudget: resourceBudget
            )
        } catch {
            return reject(transition.id, reason: .hostContract(error), context: transition.context)
        }

        let isUnchanged = hostReplacement == nil && transition.proposedState == transition.initialState
        // Catalog resolvers and equality are synchronous application work. A
        // cancellation or captured authority change during validation must be
        // observed before entering the irreversible publication section.
        if let rejection = executionPrecondition?(state) {
            return reject(transition.id, reason: rejection, context: transition.context)
        }
        guard !requestCancellationIsPending(transition.id) else {
            return reject(transition.id, reason: .cancelled, context: transition.context)
        }
        if isUnchanged {
            let previousScopes = Array(scopes.values)
            let retired = updateScopeLifetimes(after: state, mutation: lifetimeMutation, requestRootID: requestRootID)
            finishDismissedPresentations(
                ids: retired, before: transition.initialState, action: transition.action,
                owner: presentationCompletionOwner
            )
            return unchangedOutcome(
                id: transition.id, state: state, revision: revision,
                action: transition.action, context: transition.context,
                including: previousScopes
            )
        }
        return commitOutcome(
            id: transition.id,
            requestRootID: requestRootID,
            before: transition.initialState,
            after: transition.proposedState,
            action: transition.action,
            context: transition.context,
            lifetimeMutation: lifetimeMutation,
            hostReplacement: hostReplacement,
            presentationCompletionOwner: presentationCompletionOwner
        )
    }

    func makeProposedState(
        _ action: RouterAction<R>,
        from initialState: RouterState<R>,
        hostReplacement: RouterHostReplacement<R>?
    ) throws -> RouterState<R> {
        let proposedState = try RouterReducer.reduce(action, from: initialState, resourceBudget: resourceBudget)
        try (hostReplacement?.descriptor ?? hostDescriptor)?.validate(proposedState, resourceBudget: resourceBudget)
        if let error = Self.sceneCatalogValidationError(in: proposedState) {
            throw error
        }
        return proposedState
    }

    func unchangedOutcome(
        id: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        action: RouterAction<R>,
        context: RouterTransitionContext,
        including previousScopes: [WeakRouterScope<R>] = []
    ) -> RouterOutcome<R> {
        refreshScopes(after: action, context: context, including: previousScopes)
        emit(.unchanged(
            transitionID: id,
            state: state,
            revision: revision,
            context: context
        ))
        return .unchanged(id: id, state: state, revision: revision)
    }

    func commitOutcome(
        id: RouterTransitionID,
        requestRootID: RouterTransitionID,
        before: RouterState<R>,
        after: RouterState<R>,
        action: RouterAction<R>,
        context: RouterTransitionContext,
        lifetimeMutation: RouterScopeLifetimeMutation,
        hostReplacement: RouterHostReplacement<R>?,
        presentationCompletionOwner: RouterPresentationCompletionOwner
    ) -> RouterOutcome<R> {
        let previousScopes = Array(scopes.values)
        let retired = updateScopeLifetimes(after: after, mutation: lifetimeMutation, requestRootID: requestRootID)
        updateSceneLifecycleTokens(before: before, after: after)
        commit(after, hostReplacement: hostReplacement, animation: context.animation)
        refreshScopes(after: action, context: context, including: previousScopes)
        finishDismissedPresentations(
            ids: retired,
            before: before,
            action: action,
            owner: presentationCompletionOwner
        )
        emit(.committed(
            transitionID: id,
            before: before,
            after: after,
            revision: revision,
            context: context
        ))
        return .applied(id: id, before: before, after: after, revision: revision)
    }

    func commit(
        _ proposedState: RouterState<R>,
        hostReplacement: RouterHostReplacement<R>?,
        animation: RouterAnimation?
    ) {
        RouterNativeTransaction.commit(animation: animation) {
            committedValue = .init(
                state: proposedState,
                hostDescriptor: hostReplacement?.descriptor ?? hostDescriptor,
                hostGeneration: hostReplacement == nil ? committedValue.hostGeneration : UUID(),
                revision: revision &+ 1
            )
        }
    }
}
