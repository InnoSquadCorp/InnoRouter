import Foundation
import Synchronization

/// The kind of durable command a caller reserved.
package enum RouterDurabilityCommand: Sendable {
    case save
    case remove
}

/// Runs one driver's durable commands in the order that driver accepted them.
///
/// Actor isolation only provides mutual exclusion. Two commands that suspend
/// into the same storage actor resume in priority order, so a high priority
/// remove can overtake a low priority save that was accepted first and leave
/// the removed bytes back on disk. Callers therefore reserve a slot
/// synchronously — before the first suspension of the command — and reach
/// storage one at a time in that order.
///
/// Reserving a remove also invalidates every save accepted before it: those
/// saves describe state the caller has since asked to delete, so they must not
/// reach storage even if they were already past their own staleness checks.
/// A reservation that never reaches storage, such as one whose encode failed,
/// releases its slot without blocking the commands behind it.
///
/// The gate owns no navigation state and no storage. It only decides which
/// reservation runs next, and each driver owns its own gate so unrelated
/// drivers never serialize against each other.
package final class RouterDurabilityGate: Sendable {
    private struct State {
        var nextTicket: UInt64 = 0
        var serving: UInt64 = 0
        var outstandingSaves: Set<UInt64> = []
        var invalidated: Set<UInt64> = []
        var completed: Set<UInt64> = []
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    }

    private let state = Mutex(State())

    package init() {}

    /// Reserves the next slot for `command`.
    ///
    /// Synchronous on purpose: the caller's position is fixed before it
    /// suspends to encode or to reach storage, so acceptance order and
    /// execution order cannot diverge.
    package func reserve(_ command: RouterDurabilityCommand) -> UInt64 {
        state.withLock { state in
            let ticket = state.nextTicket
            state.nextTicket &+= 1
            switch command {
            case .save:
                state.outstandingSaves.insert(ticket)
            case .remove:
                state.invalidated.formUnion(state.outstandingSaves)
                state.outstandingSaves.removeAll()
            }
            return ticket
        }
    }

    /// Waits for this reservation's turn to touch storage.
    ///
    /// Returns `false` when a later remove invalidated the reservation, in
    /// which case the caller must not write. The caller releases the slot with
    /// ``finish(_:)`` either way.
    package func waitForTurn(_ ticket: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let immediate: Bool? = state.withLock { state in
                if state.invalidated.contains(ticket) {
                    return false
                }
                if state.serving == ticket {
                    return true
                }
                state.waiters[ticket] = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    /// Releases a reservation so the next one can run.
    ///
    /// Call exactly once for every ``reserve(_:)``, including reservations
    /// that never reached storage.
    package func finish(_ ticket: UInt64) {
        var resumptions: [(CheckedContinuation<Bool, Never>, Bool)] = []
        state.withLock { state in
            state.outstandingSaves.remove(ticket)
            state.invalidated.remove(ticket)
            state.completed.insert(ticket)
            advance(&state, resumptions: &resumptions)
        }
        for (continuation, allowed) in resumptions {
            continuation.resume(returning: allowed)
        }
    }

    /// Moves `serving` past finished slots and wakes whoever owns the new head.
    private func advance(
        _ state: inout State,
        resumptions: inout [(CheckedContinuation<Bool, Never>, Bool)]
    ) {
        while true {
            let current = state.serving
            if state.completed.remove(current) != nil {
                state.serving &+= 1
                continue
            }
            if let waiter = state.waiters.removeValue(forKey: current) {
                resumptions.append((waiter, !state.invalidated.contains(current)))
            }
            // The head either just started or has not asked for its turn yet.
            return
        }
    }
}
