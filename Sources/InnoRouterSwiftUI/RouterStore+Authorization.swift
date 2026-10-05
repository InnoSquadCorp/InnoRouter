import InnoRouterCore

@MainActor
extension RouterStore {
    /// Capture app authorization epochs before scheduling, so queued requests
    /// cannot silently acquire a different account's authority. The closure is
    /// runtime-only and follows the same queue/deferral lifetime as the request.
    func authorizationPrecondition(
        request: RouterRequestAuthorization<R>?,
        existing: RouterRequestPrecondition<R>?,
        captureHostGeneration: Bool = true
    ) -> RouterRequestPrecondition<R>? {
        // This function is also the pre-worker capture boundary used by
        // snapshots, partial restore, pending links and typed presentations.
        let existing = captureHostGeneration ? hostGenerationPrecondition(existing: existing) : existing
        let generations = authorizationConfigurations(for: request).compactMap { configuration in
            configuration.generation.map { provider in (provider, provider()) }
        }
        guard !generations.isEmpty else { return existing }
        return { state in
            if let rejection = existing?(state) { return rejection }
            for (provider, expected) in generations where provider() != expected {
                return .authorization(.init(code: .generationChanged))
            }
            return nil
        }
    }

    func prepareAuthorization(
        for transition: RouterTransition<R>,
        request: RouterRequestAuthorization<R>?,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterRejectionReason? {
        // An OS-failed scene must be removed even after logout. This narrowly
        // scoped repair cannot introduce routes and still passes lifetime,
        // cancellation, reducer, and revision checks. Generic policy bypass is
        // deliberately insufficient to bypass authoritative authorization.
        if isRemovalOnlySystemRepair(transition.action, identity: activeSystemRepairIdentity) { return nil }
        for configuration in authorizationConfigurations(for: request) {
            guard !requestCancellationIsPending(transition.id) else { return .cancelled }
            if let rejection = executionPrecondition?(state) { return rejection }
            let targets: [R]
            do {
                targets = try configuration.targets(
                    in: transition.proposedState, matchedRoutes: request?.matchedRoutes ?? []
                )
            } catch let failure as RouterAuthorizationFailure {
                return .authorization(failure)
            } catch {
                preconditionFailure("Authorization target resolution produced an undocumented error")
            }
            guard let gated = targets.first(where: configuration.requiresAuthorization) else { continue }
            let rejection = await authorizationDecision(configuration, transitionID: transition.id)
            guard !requestCancellationIsPending(transition.id) else { return .cancelled }
            if let rejection = executionPrecondition?(state) { return rejection }
            guard revision == transition.initialRevision else {
                return .staleState(expectedRevision: transition.initialRevision, actualRevision: revision)
            }
            if let rejection {
                if case .authorization(let failure) = rejection, failure.code == .denied {
                    request?.deniedRoute = gated
                }
                return rejection
            }
        }
        return nil
    }

    private func authorizationDecision(
        _ configuration: RouterAuthorizationConfiguration<R>,
        transitionID: RouterTransitionID
    ) async -> RouterRejectionReason? {
        if let policyTimeout, policyTimeout <= .zero {
            return .authorization(.init(code: .timedOut))
        }
        let reservation: RouterOperationRegistry.Reservation
        switch policyOperations.reserve() {
        case .success(let value): reservation = value
        case .failure(let capacity):
            return .authorization(.init(code: .capacityExceeded, limit: capacity.limit))
        }
        let race = RouterTimeoutRace<Bool>()
        activeAuthorizationRaces[transitionID] = race
        let result = await race.run(
            timeout: policyTimeout,
            sleep: runtimeDependencies.sleep,
            reservation: reservation,
            operation: configuration.authorize
        )
        if activeAuthorizationRaces[transitionID] === race {
            activeAuthorizationRaces.removeValue(forKey: transitionID)
        }
        switch result {
        case .value(true): return nil
        case .value(false): return .authorization(.init(code: .denied))
        case .timedOut: return .authorization(.init(code: .timedOut))
        case .cancelled: return .cancelled
        }
    }

    func isRemovalOnlySystemRepair(
        _ action: RouterAction<R>, identity: RouterSystemRepairIdentity?
    ) -> Bool {
        switch (action, identity) {
        case (.dismissWindow(let id), .window(let expected, let token)):
            return id == expected && windowLifecycleTokens[id] == token
        case (.dismissImmersiveSpace, .immersiveSpace(let id, let token)):
            return state.immersiveSpace?.id == id && immersiveSpaceLifecycleToken == token
        default:
            return false
        }
    }

    func authorizationConfigurations(for request: RouterRequestAuthorization<R>?) -> [RouterAuthorizationConfiguration<R>] {
        [authorization, request?.configuration].compactMap { $0 }
    }
}
