import Foundation

import InnoRouterCore

@MainActor
package final class RouterImmersiveSceneEffectQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isExecuting = false
    private var waiters: [Waiter] = []

    package init() {}

    package func enqueue(
        _ operation: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        let waiterID = UUID()
        let acquiredTurn = await withTaskCancellationHandler {
            if isExecuting {
                return await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            } else {
                isExecuting = true
                return true
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }

        guard acquiredTurn else { return false }
        guard !Task.isCancelled else {
            finishTurn()
            return false
        }
        let result = await operation()
        finishTurn()
        return result
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func finishTurn() {
        if waiters.isEmpty {
            isExecuting = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

@MainActor
package struct RouterImmersiveSceneActions {
    package let open: @MainActor @Sendable (String) async -> RouterImmersiveSpaceOpenResult
    package let dismiss: @MainActor @Sendable () async -> Void
    package let openActivation: (@MainActor @Sendable (RouterImmersiveActivation) async -> RouterImmersiveSpaceOpenResult)?

    package init(
        open: @escaping @MainActor @Sendable (String) async -> RouterImmersiveSpaceOpenResult,
        dismiss: @escaping @MainActor @Sendable () async -> Void,
        openActivation: (@MainActor @Sendable (RouterImmersiveActivation) async -> RouterImmersiveSpaceOpenResult)? = nil
    ) {
        self.open = open
        self.dismiss = dismiss
        self.openActivation = openActivation
    }
}

@MainActor
package final class RouterSceneRestorationRegistry {
    package static let immersiveEffectQueue = RouterImmersiveSceneEffectQueue()

    private struct WindowLifetime: Hashable {
        let id: UUID
        let token: UUID
    }

    private struct ImmersiveSpaceLifetime: Hashable {
        let id: String
        let token: UUID
    }

    private var restoringWindows: [WindowLifetime: UUID] = [:]
    private var restoringImmersiveSpaces: [ImmersiveSpaceLifetime: UUID] = [:]
    package private(set) var immersiveActionsOwner: UUID?
    package private(set) var immersiveActions: RouterImmersiveSceneActions?
    private var attributedImmersiveIDs: Set<String> = []

    package func declareAttributedImmersiveSpace(id: String) { attributedImmersiveIDs.insert(id) }
    package func hasAttributedImmersiveSpace(id: String) -> Bool { attributedImmersiveIDs.contains(id) }

    package init() {}

    package func installImmersiveActions(_ actions: RouterImmersiveSceneActions, owner: UUID) {
        RouterSceneLifecycleTrace.record("actions.install", "owner=\(owner)")
        immersiveActionsOwner = owner
        immersiveActions = actions
    }

    package func removeImmersiveActions(owner: UUID) {
        RouterSceneLifecycleTrace.record("actions.remove", "owner=\(owner) current=\(String(describing: immersiveActionsOwner))")
        guard immersiveActionsOwner == owner else { return }
        immersiveActionsOwner = nil
        immersiveActions = nil
    }

    package func beginWindowRestoration(id: UUID, lifecycleToken: UUID) -> UUID? {
        let lifetime = WindowLifetime(id: id, token: lifecycleToken)
        guard restoringWindows[lifetime] == nil else { return nil }
        let ticket = UUID()
        restoringWindows[lifetime] = ticket
        return ticket
    }

    package func isCurrentWindowRestoration(
        id: UUID,
        lifecycleToken: UUID,
        ticket: UUID
    ) -> Bool {
        restoringWindows[WindowLifetime(id: id, token: lifecycleToken)] == ticket
    }

    package func finishWindowRestoration(
        id: UUID,
        lifecycleToken: UUID,
        ticket: UUID? = nil
    ) {
        let lifetime = WindowLifetime(id: id, token: lifecycleToken)
        guard ticket == nil || restoringWindows[lifetime] == ticket else { return }
        restoringWindows[lifetime] = nil
    }

    package func beginImmersiveSpaceRestoration(
        id: String,
        lifecycleToken: UUID
    ) -> UUID? {
        let lifetime = ImmersiveSpaceLifetime(id: id, token: lifecycleToken)
        guard restoringImmersiveSpaces[lifetime] == nil else { return nil }
        let ticket = UUID()
        restoringImmersiveSpaces[lifetime] = ticket
        RouterSceneLifecycleTrace.record("ticket.begin", "lifetime=\(lifecycleToken) ticket=\(ticket)")
        return ticket
    }

    package func isCurrentImmersiveSpaceRestoration(
        id: String,
        lifecycleToken: UUID,
        ticket: UUID
    ) -> Bool {
        restoringImmersiveSpaces[
            ImmersiveSpaceLifetime(id: id, token: lifecycleToken)
        ] == ticket
    }

    package func finishImmersiveSpaceRestoration(
        id: String,
        lifecycleToken: UUID,
        ticket: UUID? = nil
    ) {
        let lifetime = ImmersiveSpaceLifetime(id: id, token: lifecycleToken)
        RouterSceneLifecycleTrace.record("ticket.finish", "lifetime=\(lifecycleToken) ticket=\(String(describing: ticket)) current=\(String(describing: restoringImmersiveSpaces[lifetime]))")
        guard ticket == nil || restoringImmersiveSpaces[lifetime] == ticket else { return }
        restoringImmersiveSpaces[lifetime] = nil
    }
}

package enum RouterImmersiveSpaceOpenResult: Sendable, Equatable {
    case opened
    case userCancelled
    case error
}

// Shared by the native callback and ordered lifecycle contract tests.
@MainActor
package func admitRouterImmersiveSpaceAppearance<R: Route>(
    id: String,
    lifecycleToken: UUID?,
    store: RouterStore<R>,
    executionPrecondition: RouterRequestPrecondition<R>?
) -> Bool {
    guard let lifecycleToken, let executionPrecondition,
          executionPrecondition(store.state) == nil else {
        RouterSceneLifecycleTrace.record("appearance.rejected", "revision=\(store.revision)")
        return false
    }
    RouterSceneLifecycleTrace.record("appearance.admitted", "lifetime=\(lifecycleToken) revision=\(store.revision)")
    store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
        id: id, lifecycleToken: lifecycleToken
    )
    return true
}

@MainActor
package func restoreRouterImmersiveSpaceAfterDeferredClosure<R: Route>(
    id: String,
    lifecycleToken: UUID,
    ticket: UUID,
    store: RouterStore<R>,
    open: @escaping @MainActor @Sendable () async -> RouterImmersiveSpaceOpenResult,
    dismiss: @escaping @MainActor @Sendable () async -> Void,
    executionPrecondition: RouterRequestPrecondition<R>? = nil,
    deferredClose: RouterDeferralID? = nil
) async -> Bool {
    let requestPrecondition = executionPrecondition ?? store.scopeLifetimePrecondition(at: .immersiveSpace(id))
    return await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue {
        [id, lifecycleToken, ticket, store, open, dismiss] in
        RouterSceneLifecycleTrace.record("restore.enter", "lifetime=\(lifecycleToken) ticket=\(ticket) revision=\(store.revision)")
        var keepsReservation = false
        defer {
            if !keepsReservation {
                store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(
                    id: id,
                    lifecycleToken: lifecycleToken,
                    ticket: ticket
                )
            }
        }

        guard requestPrecondition(store.state) == nil,
              store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(
            id: id,
            lifecycleToken: lifecycleToken,
            ticket: ticket
        ), store.state.immersiveSpace?.id == id,
           store.immersiveSpaceLifecycleToken == lifecycleToken else {
            return false
        }

        // Restoration may outlive the disappeared scene's SwiftUI environment.
        // Use the surviving scene driver's actions when one is registered.
        let actions = store.sceneRestorationRegistry.immersiveActions
        let usesAttribution = store.sceneRestorationRegistry.hasAttributedImmersiveSpace(id: id)
        let activation = if usesAttribution, actions?.openActivation != nil,
                            let owner = store.sceneRestorationRegistry.immersiveActionsOwner {
            store.beginAttributedImmersiveOpen(
                id: id, lifecycleToken: lifecycleToken, owner: owner,
                permitsRecovery: true, ticket: ticket, deferredClose: deferredClose
            )
        } else { Optional<RouterImmersiveActivation>.none }
        RouterSceneLifecycleTrace.record("restore.open.call", "source=\(actions == nil ? "fallback" : "driver") lifetime=\(lifecycleToken) ticket=\(ticket) revision=\(store.revision)")
        let result = if let activation, let openActivation = actions?.openActivation {
            await openActivation(activation)
        } else if usesAttribution {
            RouterImmersiveSpaceOpenResult.error
        } else if let actions {
            await actions.open(id)
        } else {
            await open()
        }
        if let activation {
            guard store.returnedAttributedImmersiveOpen(result, activation: activation) else {
                if result == .opened { await actions?.dismiss() }
                return false
            }
        }
        RouterSceneLifecycleTrace.record("restore.open.return", "result=\(result) lifetime=\(lifecycleToken) ticket=\(ticket) revision=\(store.revision) currentLifetime=\(String(describing: store.immersiveSpaceLifecycleToken))")
        guard store.state.immersiveSpace?.id == id,
              store.immersiveSpaceLifecycleToken == lifecycleToken else {
            if result == .opened {
                if let actions {
                    await actions.dismiss()
                } else {
                    await dismiss()
                }
            }
            return false
        }
        guard requestPrecondition(store.state) == nil else { return false }
        guard store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(
            id: id,
            lifecycleToken: lifecycleToken,
            ticket: ticket
        ) else {
            // A matching appearance consumes the reservation before
            // openImmersiveSpace returns. The canonical lifetime is still
            // current, so that successful open must not be compensated.
            return result == .opened
        }

        switch result {
        case .opened:
            keepsReservation = true
            return true
        case .userCancelled, .error:
            RouterSceneLifecycleTrace.record("repair.submit", "lifetime=\(lifecycleToken) ticket=\(ticket) revision=\(store.revision)")
            let repair = await store.reconcileSceneSystemFailure(
                .dismissImmersiveSpace,
                executionPrecondition: immersiveRestorationRepairPrecondition(
                    id: id, lifecycleToken: lifecycleToken, ticket: ticket,
                    store: store, activation: activation, result: result,
                    requestPrecondition: requestPrecondition
                )
            )
            let applied: Bool = if case .applied = repair { true } else { false }
            RouterSceneLifecycleTrace.record("repair.return", "applied=\(applied) lifetime=\(lifecycleToken) ticket=\(ticket) revision=\(store.revision) canonical=\(store.state.immersiveSpace != nil)")
            return false
        }
    }
}

@MainActor
private func immersiveRestorationRepairPrecondition<R: Route>(
    id: String, lifecycleToken: UUID, ticket: UUID,
    store: RouterStore<R>, activation: RouterImmersiveActivation?,
    result: RouterImmersiveSpaceOpenResult,
    requestPrecondition: @escaping RouterRequestPrecondition<R>
) -> RouterRequestPrecondition<R> {
    { [weak store] state in
        // Recheck the ticket after any queued Store work. Matching appearance
        // or a newer restoration may have consumed it while work was suspended.
        RouterSceneLifecycleTrace.record("repair.precondition", "lifetime=\(lifecycleToken) ticket=\(ticket) revision=\(String(describing: store?.revision)) currentLifetime=\(String(describing: store?.immersiveSpaceLifecycleToken)) currentTicket=\(store?.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(id: id, lifecycleToken: lifecycleToken, ticket: ticket) == true)")
        guard let store,
              state.immersiveSpace?.id == id,
              store.immersiveSpaceLifecycleToken == lifecycleToken,
              store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(
                  id: id, lifecycleToken: lifecycleToken, ticket: ticket
              ) else { return .cancelled }
        if let activation {
            guard store.sceneRestorationRegistry.immersiveActionsOwner == activation.driverOwner else { return .cancelled }
            if result == .error, store.currentImmersiveActivation(activation) == nil { return .cancelled }
        }
        return requestPrecondition(state)
    }
}

@MainActor
package func shouldRestoreRouterScene<R: Route>(
    after outcome: RouterOutcome<R>
) -> Bool {
    switch outcome {
    case .deferred, .rejected:
        true
    case .applied, .unchanged:
        false
    }
}

@MainActor
package func synchronizeRouterWindowDisappearance<R: Route>(
    id: UUID,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard let lifecycleToken = store.windowLifecycleTokens[id] else {
        return nil
    }
    return await synchronizeRouterWindowDisappearance(
        id: id,
        lifecycleToken: lifecycleToken,
        store: store
    )
}

@MainActor
package func synchronizeRouterWindowDisappearance<R: Route>(
    id: UUID,
    lifecycleToken: UUID,
    store: RouterStore<R>,
    executionPrecondition: RouterRequestPrecondition<R>? = nil
) async -> RouterOutcome<R>? {
    guard store.state.windows.contains(where: { $0.id == id }),
          store.windowLifecycleTokens[id] == lifecycleToken else { return nil }
    let requestPrecondition = executionPrecondition ?? store.scopeLifetimePrecondition(at: .window(id))
    guard requestPrecondition(store.state) == nil else { return nil }
    return await store.perform(
        .dismissWindow(id),
        context: .init(source: .system),
        expectedRevision: nil,
        bypassesPolicies: false,
        executionPrecondition: { [weak store] state in
            guard state.windows.contains(where: { $0.id == id }) else {
                return .mutation(.windowNotFound(id))
            }
            guard store?.windowLifecycleTokens[id] == lifecycleToken else {
                return .cancelled
            }
            return requestPrecondition(state)
        }
    )
}

@MainActor
package func synchronizeRouterImmersiveSpaceDisappearance<R: Route>(
    id: String,
    store: RouterStore<R>
) async -> RouterOutcome<R>? {
    guard store.state.immersiveSpace?.id == id,
          let lifecycleToken = store.immersiveSpaceLifecycleToken else {
        return nil
    }
    return await synchronizeRouterImmersiveSpaceDisappearance(
        id: id,
        lifecycleToken: lifecycleToken,
        store: store
    )
}

@MainActor
package func synchronizeRouterImmersiveSpaceDisappearance<R: Route>(
    id: String,
    lifecycleToken: UUID,
    store: RouterStore<R>,
    executionPrecondition: RouterRequestPrecondition<R>? = nil
) async -> RouterOutcome<R>? {
    guard store.state.immersiveSpace?.id == id,
          store.immersiveSpaceLifecycleToken == lifecycleToken else {
        return nil
    }
    let requestPrecondition = executionPrecondition ?? store.scopeLifetimePrecondition(at: .immersiveSpace(id))
    guard requestPrecondition(store.state) == nil else { return nil }
    return await store.perform(
        .dismissImmersiveSpace,
        context: .init(source: .system),
        expectedRevision: nil,
        bypassesPolicies: false,
        executionPrecondition: { [weak store] state in
            guard state.immersiveSpace?.id == id else {
                return .mutation(.immersiveSpaceNotFound(id))
            }
            guard store?.immersiveSpaceLifecycleToken == lifecycleToken else {
                return .cancelled
            }
            return requestPrecondition(state)
        }
    )
}
