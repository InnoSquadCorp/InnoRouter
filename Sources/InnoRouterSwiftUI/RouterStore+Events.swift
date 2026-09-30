// MARK: - RouterStore+Events.swift
// InnoRouterSwiftUI - terminal event emission and scope reconciliation
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

extension RouterStore {
    func observeRequest(
        id: RouterTransitionID,
        action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64? = nil,
        semantics: RouterRequestSemantics<R> = .action
    ) {
        let observation = RouterRequestObservation(
            id: id,
            action: action,
            context: context,
            expectedRevision: expectedRevision,
            semantics: semantics
        )
        Array(synchronousRequestObservers.values).forEach { $0(observation) }
        requestBroadcaster.broadcast(observation)
    }

    func reject(
        _ transitionID: RouterTransitionID,
        reason: RouterRejectionReason,
        context: RouterTransitionContext,
        action: RouterAction<R>? = nil
    ) -> RouterOutcome<R> {
        let outcome = RouterOutcome<R>.rejected(
            id: transitionID,
            state: state,
            revision: revision,
            reason: reason
        )
        emit(.rejected(
            transitionID: transitionID,
            state: state,
            revision: revision,
            reason: reason,
            context: context
        ))
        refreshScopes(after: action, context: context)
        return outcome
    }

    package func rejectRequest(
        reason: RouterRejectionReason,
        context: RouterTransitionContext = .init(),
        action: RouterAction<R>? = nil
    ) -> RouterOutcome<R> {
        reject(
            runtimeDependencies.makeTransitionID(),
            reason: reason,
            context: context,
            action: action
        )
    }

    package func emit(_ event: RouterEvent<R>) {
        onEvent?(event)
        Array(synchronousEventObservers.values).forEach { $0(event) }
        broadcaster.broadcast(event)
    }

    @discardableResult
    package func addSynchronousEventObserver(
        _ observer: @escaping @MainActor @Sendable (RouterEvent<R>) -> Void
    ) -> UUID {
        let id = UUID()
        synchronousEventObservers[id] = observer
        return id
    }

    package func removeSynchronousEventObserver(_ id: UUID) {
        synchronousEventObservers.removeValue(forKey: id)
    }

    /// Number of event observation lifetimes owned by async and synchronous
    /// package integrations. Kept at package visibility for leak assertions.
    package var eventObservationCount: Int {
        broadcaster.subscriberCount + synchronousEventObservers.count
    }

    @discardableResult
    package func addSynchronousRequestObserver(
        _ observer: @escaping @MainActor @Sendable (RouterRequestObservation<R>) -> Void
    ) -> UUID {
        let id = UUID()
        synchronousRequestObservers[id] = observer
        return id
    }

    package func removeSynchronousRequestObserver(_ id: UUID) {
        synchronousRequestObservers.removeValue(forKey: id)
    }

    @discardableResult
    package func addSynchronousCancellationObserver(
        _ observer: @escaping @MainActor @Sendable (RouterTransitionID) -> Void
    ) -> UUID {
        let id = UUID()
        synchronousCancellationObservers[id] = observer
        return id
    }

    package func removeSynchronousCancellationObserver(_ id: UUID) {
        synchronousCancellationObservers.removeValue(forKey: id)
    }

    func observeCancellation(_ id: RouterTransitionID) {
        Array(synchronousCancellationObservers.values).forEach { $0(id) }
    }

    func refreshScopes(
        after action: RouterAction<R>?,
        context: RouterTransitionContext
    ) {
        compactDeadScopes()
        let liveScopes = scopes.values.compactMap(\.value)
        let reconciliationTarget: RouterScopePath??
        if context.source == .system {
            reconciliationTarget = .some(action?.systemReconciliationTarget())
        } else {
            reconciliationTarget = .none
        }
        for scope in liveScopes {
            let shouldReconcile: Bool
            switch reconciliationTarget {
            case .none:
                shouldReconcile = false
            case .some(.none):
                shouldReconcile = true
            case .some(.some(let path)):
                shouldReconcile = scope.path == path
            }
            scope.refresh(
                from: state,
                reconcileSystemBinding: shouldReconcile
            )
        }
    }
}

private extension RouterAction {
    /// Exact host binding that originated a system request. `nil` means a
    /// whole-state plan whose native bindings must all re-read canonical state.
    func systemReconciliationTarget(
        from path: RouterScopePath = .root
    ) -> RouterScopePath? {
        switch self {
        case .scoped(let scope, let action):
            action.systemReconciliationTarget(from: path.appending(scope))
        case .windowScoped(let id, let action):
            action.systemReconciliationTarget(from: .window(id))
        case .immersiveSpaceScoped(let id, let action):
            action.systemReconciliationTarget(from: .immersiveSpace(id))
        case .apply:
            nil
        case .openWindow, .dismissWindow,
             .enterImmersiveSpace, .dismissImmersiveSpace:
            .root
        default:
            path
        }
    }
}
