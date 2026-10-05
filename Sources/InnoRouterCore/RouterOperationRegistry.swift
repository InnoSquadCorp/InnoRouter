// MARK: - RouterOperationRegistry.swift
// InnoRouterCore - bounded ownership of actually running operations
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Owns operation tasks independently of a Store and their logical waiters.
///
/// Reservations count against the bound before a task is created. Cancelling
/// or timing out a waiter does not free a running task's slot: only the exit of
/// its operation closure does. Swift cancellation cannot forcibly stop app code.
@MainActor
package final class RouterOperationRegistry {
    package struct CapacityExceeded: Error, Sendable {
        package let limit: Int
    }

    @MainActor
    package struct Reservation {
        fileprivate let registry: RouterOperationRegistry
        fileprivate let id: UUID

        /// Starts exactly one operation under this reservation.
        package func start(
            _ operation: @escaping @MainActor @Sendable () async -> Void
        ) -> Task<Void, Never> {
            registry.start(id, operation: operation)
        }

        /// Returns an unused reservation without creating an operation task.
        package func abandonBeforeStart() {
            registry.abandonBeforeStart(id)
        }
    }

    private struct Entry {
        var task: Task<Void, Never>?
    }

    package let maximumCount: Int?
    private var entries: [UUID: Entry] = [:]

    /// Includes reserved slots and operations still alive after logical completion.
    package var activeCount: Int { entries.count }

    package init(maximumCount: Int?) {
        self.maximumCount = maximumCount.map { max(0, $0) }
    }

    package func reserve() -> Result<Reservation, CapacityExceeded> {
        if let maximumCount, entries.count >= maximumCount {
            return .failure(CapacityExceeded(limit: maximumCount))
        }
        let id = UUID()
        entries[id] = Entry()
        return .success(Reservation(registry: self, id: id))
    }

    private func start(
        _ id: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        precondition(entries[id] != nil, "Operation requires an active reservation")
        precondition(entries[id]?.task == nil, "Operation reservation can only start once")
        let task = Task { @MainActor [self] in
            // This retention is intentional: a timed-out, noncooperative task
            // keeps its registry alive, without retaining a Store through it.
            defer { entries.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        entries[id]?.task = task
        return task
    }

    private func abandonBeforeStart(_ id: UUID) {
        guard let entry = entries[id] else { return }
        precondition(entry.task == nil, "A running operation releases its own slot on exit")
        entries.removeValue(forKey: id)
    }
}
