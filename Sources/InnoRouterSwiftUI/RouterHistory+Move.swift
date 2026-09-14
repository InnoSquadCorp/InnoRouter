import Foundation

import InnoRouterCore

extension RouterHistory {
    package func waitForActiveRequestTerminal(_ requestRootID: RouterTransitionID) async {
        guard activeRequestMoves[requestRootID] != nil else { return }
        await withCheckedContinuation { continuation in
            activeRequestTerminalWaiters[requestRootID] = continuation
        }
    }

    package func apply(
        _ entry: RouterHistoryEntry<R>,
        destinationCursor: Int?,
        operationID: UUID
    ) async -> RouterHistoryMoveResult<R> {
        let startingGeneration = generation
        let expectedRevision = store.revision
        let restoredState: RouterState<R>
        let restorationReport: RouterPartialRestorationReport?
        if let validator {
            do {
                let prepared = try await preparePartialRestoration(
                    entry.navigationState,
                    validator: validator,
                    timeout: validationTimeout,
                    sleep: store.runtimeDependencies.sleep
                )
                restoredState = prepared.0
                restorationReport = prepared.1
            } catch let error as RouterPartialRestorationError {
                return .unavailable(cursor: cursor, reason: .validationFailed(error))
            } catch {
                return .unavailable(
                    cursor: cursor,
                    reason: .validationFailed(.validationFailed(String(describing: error)))
                )
            }
        } else {
            restoredState = entry.navigationState
            restorationReport = nil
        }
        guard !Task.isCancelled,
              !isStopped,
              generation == startingGeneration else {
            return .unavailable(
                cursor: cursor,
                reason: isStopped ? .stopped : .cancelled
            )
        }
        lastRestorationReport = restorationReport
        let target: RouterState<R>
        do {
            target = try Self.merge(restoredState, into: store.state)
        } catch let failure as RouterHistoryFailure {
            return .unavailable(cursor: cursor, reason: failure)
        } catch {
            return .unavailable(cursor: cursor, reason: .incompatibleTopology(.root))
        }
        let requestRootID = store.reserveTransitionID()
        ownedRequestRoots.insert(requestRootID)
        activeMoveRequestRoots[operationID] = requestRootID
        activeRequestMoves[requestRootID] = .init(
            generation: startingGeneration,
            requestRootID: requestRootID,
            entry: entry,
            destinationCursor: destinationCursor
        )
        let outcome = await store.perform(
            .apply(RouterPlan(state: target)),
            context: .init(source: .history),
            expectedRevision: expectedRevision,
            bypassesPolicies: false,
            transitionID: requestRootID,
            requestRootID: requestRootID,
            requestSemantics: .historyNavigation(restoredState),
            executionPrecondition: { [weak self] _ in
                guard let self,
                      !self.isStopped,
                      self.generation == startingGeneration else {
                    return .cancelled
                }
                return nil
            },
            deferredResumePreparation: { [weak self] currentState, _ in
                guard let self,
                      !self.isStopped,
                      self.generation == startingGeneration else {
                    return .rejected(.cancelled)
                }
                return Self.prepareNavigationMerge(restoredState, into: currentState)
            }
        )
        switch outcome {
        case .applied, .unchanged:
            await waitForActiveRequestTerminal(requestRootID)
            activeRequestMoves.removeValue(forKey: requestRootID)
            ownedRequestRoots.remove(requestRootID)
            return .completed(cursor: cursor, transition: outcome)
        case .deferred(_, _, _, let deferral):
            guard !Task.isCancelled,
                  startingGeneration == generation,
                  !isStopped else {
                activeRequestMoves.removeValue(forKey: requestRootID)
                ownedRequestRoots.remove(requestRootID)
                store.cancelRequestFamily(requestRootID)
                return .unavailable(
                    cursor: cursor,
                    reason: isStopped ? .stopped : .cancelled
                )
            }
            if let pending = activeRequestMoves.removeValue(forKey: requestRootID) {
                pendingMoves[deferral.id] = pending
            }
            return .deferred(cursor: cursor, transition: outcome)
        case .rejected:
            activeRequestMoves.removeValue(forKey: requestRootID)
            ownedRequestRoots.remove(requestRootID)
            return .rejected(cursor: cursor, transition: outcome)
        }
    }
}
