import Foundation

import InnoRouterCore

// Native transport data is deliberately independent of Route.Codable. A
// decoded value acquires authority only by matching this Store's live record.
package struct RouterImmersiveActivation: Codable, Hashable, Sendable {
    package let storeID: UUID
    package let sceneID: String
    package let lifetime: UUID
    package let requestID: UUID
    package let driverOwner: UUID
}

struct RouterImmersiveDismissal<R: Route> {
    let id: UUID
    let activation: RouterImmersiveActivation
    let scene: RouterImmersiveSpace<R>
}

@MainActor
final class RouterImmersiveActivationRecord<R: Route> {
    enum Phase { case opening, awaitingAppearance, failed, repaired, recovering, adopted }
    let activation: RouterImmersiveActivation
    let permitsRecovery: Bool
    let ticket: UUID?
    let deferredClose: RouterDeferralID?
    let deferredCloseRoot: RouterTransitionID?
    let authority: RouterRequestPrecondition<R>?
    var scene: RouterImmersiveSpace<R>
    var phase: Phase = .opening
    var nativeVisible = false
    var adoptedLifetime: UUID?
    var repairBeforeRevision: UInt64?
    var repairRevision: UInt64?
    var recoveryRevision: UInt64?

    init(
        activation: RouterImmersiveActivation, scene: RouterImmersiveSpace<R>,
        permitsRecovery: Bool, ticket: UUID?, deferredClose: RouterDeferralID?,
        deferredCloseRoot: RouterTransitionID?, authority: RouterRequestPrecondition<R>?
    ) {
        self.activation = activation
        self.scene = scene
        self.permitsRecovery = permitsRecovery
        self.ticket = ticket
        self.deferredClose = deferredClose
        self.deferredCloseRoot = deferredCloseRoot
        self.authority = authority
    }
}

@MainActor
extension RouterStore {
    package func beginAttributedImmersiveOpen(
        id: String, lifecycleToken: UUID, owner: UUID,
        permitsRecovery: Bool = false, ticket: UUID? = nil,
        deferredClose: RouterDeferralID? = nil
    ) -> RouterImmersiveActivation? {
        guard sceneRestorationRegistry.immersiveActionsOwner == owner,
              state.immersiveSpace?.id == id,
              immersiveSpaceLifecycleToken == lifecycleToken,
              let scene = state.immersiveSpace else { return nil }
        let authority = authorizationPrecondition(request: nil, existing: nil)
        guard authority?(state) == nil else { return nil }
        let deferred = deferredClose.flatMap { deferredRequests[$0] }
        let matchingDeferral = deferred?.action == .dismissImmersiveSpace
            && deferred?.context.source == .system
            && deferred?.executionPrecondition?(state) == nil
        let activation = RouterImmersiveActivation(
            storeID: immersiveActivationStoreID, sceneID: id,
            lifetime: lifecycleToken, requestID: UUID(), driverOwner: owner
        )
        immersiveActivation = RouterImmersiveActivationRecord(
            activation: activation, scene: scene, permitsRecovery: permitsRecovery,
            ticket: ticket, deferredClose: matchingDeferral ? deferredClose : nil,
            deferredCloseRoot: matchingDeferral ? deferred?.rootID : nil,
            authority: authority
        )
        RouterSceneLifecycleTrace.record("activation.begin", "request=\(activation.requestID) lifetime=\(lifecycleToken) recovery=\(permitsRecovery)")
        return activation
    }

    @discardableResult
    package func returnedAttributedImmersiveOpen(
        _ result: RouterImmersiveSpaceOpenResult, activation: RouterImmersiveActivation
    ) -> Bool {
        guard let record = currentImmersiveActivation(activation) else { return false }
        guard record.phase == .opening else { return record.phase == .adopted }
        switch result {
        case .opened: record.phase = .awaitingAppearance
        case .error: record.phase = .failed
        case .userCancelled: immersiveActivation = nil
        }
        return true
    }

    func currentImmersiveActivation(_ activation: RouterImmersiveActivation) -> RouterImmersiveActivationRecord<R>? {
        guard activation.storeID == immersiveActivationStoreID,
              sceneRestorationRegistry.immersiveActionsOwner == activation.driverOwner,
              let record = immersiveActivation, record.activation == activation else { return nil }
        return record
    }

    package func hasAdoptedImmersiveAppearance(id: String, lifetime: UUID?) -> Bool {
        guard let record = immersiveActivation,
              currentImmersiveActivation(record.activation) != nil,
              record.phase == .adopted, record.nativeVisible,
              record.activation.sceneID == id,
              record.adoptedLifetime == lifetime,
              record.authority?(state) == nil else { return false }
        return true
    }

    package var hasClaimedImmersiveRecovery: Bool {
        guard let record = immersiveActivation else { return false }
        return currentImmersiveActivation(record.activation) != nil
            && (record.phase == .recovering || record.phase == .repaired) && record.nativeVisible
            && record.authority?(state) == nil
    }

    // An expired native host cannot borrow the fresh scope at a reused ID.
    func canRenderAttributedImmersiveSpace(_ activation: RouterImmersiveActivation) -> Bool {
        guard let record = currentImmersiveActivation(activation),
              state.immersiveSpace?.id == activation.sceneID,
              record.authority?(state) == nil else { return false }
        switch record.phase {
        case .opening, .awaitingAppearance, .failed:
            return immersiveSpaceLifecycleToken == activation.lifetime
        case .adopted:
            return immersiveSpaceLifecycleToken == record.adoptedLifetime
        case .repaired, .recovering:
            return false
        }
    }

    // The callback's value, not the current lifetime, identifies its attempt.
    // Mark actual native presence synchronously in onAppear. Deferring this to
    // a View Task could let a subsequent onDisappear overtake its authority.
    package func observeAttributedImmersiveAppearance(_ activation: RouterImmersiveActivation) -> Bool {
        guard let record = currentImmersiveActivation(activation), record.authority?(state) == nil else { return false }
        switch record.phase {
        case .opening, .awaitingAppearance, .failed:
            guard state.immersiveSpace?.id == activation.sceneID,
                  immersiveSpaceLifecycleToken == activation.lifetime else { return false }
            record.nativeVisible = true
            record.adoptedLifetime = activation.lifetime
            record.phase = .adopted
            if let ticket = record.ticket {
                sceneRestorationRegistry.finishImmersiveSpaceRestoration(id: activation.sceneID, lifecycleToken: activation.lifetime, ticket: ticket)
            }
            return true
        case .adopted:
            return hasAdoptedImmersiveAppearance(id: activation.sceneID, lifetime: immersiveSpaceLifecycleToken)
        case .repaired:
            if record.permitsRecovery, state.immersiveSpace == nil { record.nativeVisible = true }
            return false
        case .recovering:
            return false
        }
    }

    package func admitAttributedImmersiveAppearance(
        _ activation: RouterImmersiveActivation,
        onRecoveryClaim: (@MainActor @Sendable () -> Void)? = nil
    ) async -> Bool {
        if observeAttributedImmersiveAppearance(activation) { return true }
        guard let record = currentImmersiveActivation(activation) else { return false }
        guard record.authority?(state) == nil else {
            // A matching but revoked native callback must not retain authority
            // for a later grant. Serialize dismissal and recheck the exact
            // owner so an intervening replacement is never closed by this.
            record.nativeVisible = true
            let cleanup = Task { @MainActor [weak self] in
                await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue { [weak self] in
                    guard let self, self.currentImmersiveActivation(activation) === record else { return false }
                    self.immersiveActivation = nil
                    await self.sceneRestorationRegistry.immersiveActions?.dismiss()
                    return false
                }
            }
            return await cleanup.value
        }
        switch record.phase {
        case .opening, .awaitingAppearance, .failed:
            return false
        case .adopted:
            return hasAdoptedImmersiveAppearance(id: activation.sceneID, lifetime: immersiveSpaceLifecycleToken)
        case .repaired:
            guard record.permitsRecovery, state.immersiveSpace == nil else { return false }
            record.nativeVisible = true
            record.phase = .recovering
            onRecoveryClaim?()
        case .recovering:
            return false
        }

        // Own cleanup independently of the view Task. The queue also keeps
        // native dismiss/open effects outside the atomic Store publication.
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue {
                [weak self] in
                guard let self else { return false }
                guard self.canRecoverImmersiveActivation(activation) else {
                    await self.dismissAttributedImmersiveAttemptIfCurrent(activation)
                    return false
                }
                let outcome = await self.perform(
                    .enterImmersiveSpace(record.scene), context: .init(source: .system),
                    expectedRevision: nil, bypassesPolicies: false,
                    executionPrecondition: { [weak self] _ in
                        self?.canRecoverImmersiveActivation(activation) == true ? nil : .cancelled
                    },
                    systemRepairIdentity: .immersiveSpaceRecovery(activation)
                )
                if case .applied = outcome {
                    return self.hasAdoptedImmersiveAppearance(
                        id: activation.sceneID, lifetime: self.immersiveSpaceLifecycleToken
                    )
                }
                // A failed entry never borrows removal-only authorization.
                // Dismiss only while this exact native attempt still owns the
                // serialized effect slot; a newer owner must be untouched.
                await self.dismissAttributedImmersiveAttemptIfCurrent(activation)
                return false
            }
        }
        return await task.value
    }

    private func dismissAttributedImmersiveAttemptIfCurrent(_ activation: RouterImmersiveActivation) async {
        guard let current = currentImmersiveActivation(activation), current.nativeVisible else { return }
        current.nativeVisible = false
        immersiveActivation = nil
        await sceneRestorationRegistry.immersiveActions?.dismiss()
    }

    private func canRecoverImmersiveActivation(_ activation: RouterImmersiveActivation) -> Bool {
        guard let record = currentImmersiveActivation(activation) else { return false }
        return record.phase == .recovering && record.nativeVisible
            && record.permitsRecovery && state.immersiveSpace == nil
            && record.authority?(state) == nil
    }

    package func attributedImmersiveDisappearance(_ activation: RouterImmersiveActivation) -> UUID? {
        guard let record = immersiveActivation, record.activation == activation,
              activation.storeID == immersiveActivationStoreID,
              sceneRestorationRegistry.immersiveActionsOwner == nil
                || sceneRestorationRegistry.immersiveActionsOwner == activation.driverOwner else { return nil }
        record.nativeVisible = false
        guard record.phase == .adopted, state.immersiveSpace?.id == activation.sceneID,
              let token = record.adoptedLifetime, immersiveSpaceLifecycleToken == token,
              record.authority?(state) == nil else {
            immersiveActivation = nil
            return nil
        }
        return token
    }

    func reconcileImmersiveActivationCommit(
        before: RouterState<R>, after: RouterState<R>, action: RouterAction<R>,
        hostReplacement: Bool, oldRevision: UInt64
    ) {
        guard let record = immersiveActivation else { return }
        if !hostReplacement,
           case .immersiveSpace(let id, let token) = activeSystemRepairIdentity,
           id == record.activation.sceneID, token == record.activation.lifetime,
           action == .dismissImmersiveSpace, record.phase == .failed,
           record.permitsRecovery, let removedScene = before.immersiveSpace, removedScene.id == id,
           after.immersiveSpace == nil,
           currentImmersiveActivation(record.activation) != nil {
            record.scene = removedScene
            record.phase = .repaired
            record.repairBeforeRevision = oldRevision
            record.repairRevision = revision
            return
        }
        if !hostReplacement,
           case .immersiveSpaceRecovery(let activation) = activeSystemRepairIdentity,
           activation == record.activation, record.phase == .recovering,
           record.nativeVisible, after.immersiveSpace == record.scene,
           currentImmersiveActivation(activation) != nil {
            record.phase = .adopted
            record.adoptedLifetime = immersiveSpaceLifecycleToken
            record.recoveryRevision = revision
            RouterSceneLifecycleTrace.record("activation.recovered", "request=\(activation.requestID) revision=\(revision) lifetime=\(String(describing: immersiveSpaceLifecycleToken))")
            return
        }
        if hostReplacement || before.immersiveSpace?.id != after.immersiveSpace?.id
            || before.immersiveSpace?.route != after.immersiveSpace?.route
            || acceptsImmersiveAbsence(action, after: after) {
            revokeImmersiveActivation(record, latestScene: before.immersiveSpace)
        }
    }

    // Applied AND unchanged accepted absence invalidate outstanding native
    // claims. Policies which defer/reject never reach this acceptance boundary.
    func reconcileImmersiveActivationUnchanged(_ action: RouterAction<R>) {
        guard let record = immersiveActivation, acceptsImmersiveAbsence(action, after: state) else { return }
        revokeImmersiveActivation(record)
    }

    private func acceptsImmersiveAbsence(_ action: RouterAction<R>, after: RouterState<R>) -> Bool {
        switch action {
        case .dismissImmersiveSpace: true
        case .apply: after.immersiveSpace == nil
        default: false
        }
    }

    private func revokeImmersiveActivation(_ record: RouterImmersiveActivationRecord<R>, latestScene: RouterImmersiveSpace<R>? = nil) {
        if record.nativeVisible {
            let dismissal = RouterImmersiveDismissal(id: UUID(), activation: record.activation, scene: latestScene ?? record.scene)
            pendingImmersiveDismissal = dismissal
            immersiveDismissalEpoch = dismissal.id
        }
        immersiveActivation = nil
    }

    func prepareAttributedImmersiveDriver(owner: UUID) {
        if let record = immersiveActivation, record.activation.driverOwner != owner {
            revokeImmersiveActivation(record, latestScene: state.immersiveSpace)
        }
    }

    func finishAttributedImmersiveDismissal(_ id: UUID) {
        guard pendingImmersiveDismissal?.id == id else { return }
        pendingImmersiveDismissal = nil
        immersiveDismissalEpoch = nil
    }

    func immersiveDeferralContinuity(
        id: RouterDeferralID, request: DeferredRouterRequest<R>,
        strategy: RouterDeferralResumeStrategy
    ) -> (revision: UInt64?, precondition: RouterRequestPrecondition<R>)? {
        guard let record = immersiveActivation,
              record.deferredClose == id, record.deferredCloseRoot == request.rootID,
              request.action == .dismissImmersiveSpace, request.context.source == .system,
              record.recoveryRevision != nil,
              hasAdoptedImmersiveAppearance(id: record.activation.sceneID, lifetime: immersiveSpaceLifecycleToken),
              let token = record.adoptedLifetime else { return nil }
        if strategy == .requireUnchangedState {
            guard record.repairBeforeRevision == request.initialRevision,
                  record.repairRevision == request.initialRevision &+ 1,
                  record.recoveryRevision == request.initialRevision &+ 2,
                  revision == record.recoveryRevision else { return nil }
        }
        let activation = record.activation
        let authority = record.authority
        return (
            strategy == .requireUnchangedState ? revision : nil,
            { [weak self] state in
                guard let self, self.currentImmersiveActivation(activation) === record,
                      record.phase == .adopted, record.nativeVisible,
                      self.immersiveSpaceLifecycleToken == token,
                      state.immersiveSpace?.id == activation.sceneID else { return .cancelled }
                return authority?(state)
            }
        )
    }
}
