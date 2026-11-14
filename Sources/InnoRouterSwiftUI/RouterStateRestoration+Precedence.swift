// MARK: - RouterStateRestoration+Precedence.swift
// InnoRouterSwiftUI - initial restore ordering against concurrent navigation
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

@MainActor
extension RouterStore {
    /// Takes the execution lane for a request whose input is not available yet.
    ///
    /// The lane is owned exactly as it is by a running request, so everything
    /// admitted meanwhile queues or is rejected as busy under the Store's
    /// scheduling policy. A later `perform` that passes the same transition ID
    /// takes the lane over and runs ahead of what queued behind it. Returns
    /// `false`, and reserves nothing, when the lane is already in use.
    ///
    /// The reservation publishes no request or event of its own. The caller
    /// must either run the reserved request or call
    /// ``releaseExecutionLane(_:)``; releasing after the request ran is a
    /// no-op, so an unconditional release at the end of the caller's work is
    /// safe.
    package func reserveExecutionLane(for id: RouterTransitionID) -> Bool {
        guard activeTransitionID == nil, queuedRequests.isEmpty, queuedSystemRepairs.isEmpty else {
            return false
        }
        beginExecution(id, rootID: id, requestKey: nil, systemRepairIdentity: nil)
        reservedLaneID = id
        return true
    }

    /// Returns a reserved lane whose request never started, then starts the
    /// next queued request.
    package func releaseExecutionLane(_ id: RouterTransitionID) {
        guard reservedLaneID == id else { return }
        reservedLaneID = nil
        finishExecution(id)
    }
}

@MainActor
extension RouterRestorationDriver {
    /// Holds the Store's lane for the initial restore when the snapshot has
    /// precedence, and returns the transition ID the restore must use.
    func reserveInitialRestoreLane() -> RouterTransitionID? {
        guard initialRestorePrecedence == .snapshot, reservedRestoreLane == nil else { return nil }
        let id = store.reserveTransitionID()
        guard store.reserveExecutionLane(for: id) else { return nil }
        reservedRestoreLane = id
        return id
    }

    /// Ends the hold taken by ``reserveInitialRestoreLane()``.
    ///
    /// `lane` is the reservation of the activation that is finishing. A
    /// stopped activation's worker can finish after a newer activation
    /// reserved again, so this never releases a reservation it was not given.
    func releaseInitialRestoreLane(_ lane: RouterTransitionID?) {
        guard let lane else { return }
        if reservedRestoreLane == lane { reservedRestoreLane = nil }
        store.releaseExecutionLane(lane)
    }
}
