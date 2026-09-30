// MARK: - RouterTestClock.swift
// InnoRouterTesting - externally controllable virtual runtime time
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Synchronization

import InnoRouterCore
import InnoRouterSwiftUI

/// A virtual clock used by the production router timeout and expiry paths.
///
/// Sleeping tasks register immediately and remain suspended until `advance`
/// reaches their deadline or the task is cancelled. Tests can await an exact
/// registration count instead of guessing readiness with wall-clock sleeps or
/// repeated `Task.yield()` calls.
public final class RouterTestClock: Sendable {
    private struct Sleeper {
        let ownerID: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Barrier {
        let ownerID: UUID?
        let minimumCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var now: Date
        var sleepers: [UUID: Sleeper] = [:]
        var barriers: [UUID: Barrier] = [:]
        var cancelledBarriers: Set<UUID> = []
    }

    private let storage: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.storage = Mutex(State(now: now))
    }

    public var now: Date {
        storage.withLock { $0.now }
    }

    public var pendingSleepCount: Int {
        storage.withLock { $0.sleepers.count }
    }

    package func pendingSleepCount(ownerID: UUID) -> Int {
        storage.withLock { state in
            state.sleepers.values.reduce(into: 0) { count, sleeper in
                if sleeper.ownerID == ownerID { count += 1 }
            }
        }
    }

    /// Suspends until at least `count` runtime sleeps have registered.
    public func waitUntilScheduled(_ count: Int = 1) async {
        _ = await waitUntilScheduled(count, ownerID: nil)
    }

    package func waitUntilScheduled(_ count: Int, ownerID: UUID) async -> Bool {
        await waitUntilScheduled(count, ownerID: Optional(ownerID))
    }

    private func waitUntilScheduled(_ count: Int, ownerID: UUID?) async -> Bool {
        guard count > 0 else { return true }
        if scheduledCount(ownerID: ownerID) >= count { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard Task.isCancelled == false else { return false }
            return await withCheckedContinuation { continuation in
                let resumeNow = storage.withLock { state -> Bool in
                    if state.cancelledBarriers.remove(id) != nil { return true }
                    let scheduled = Self.scheduledCount(in: state, ownerID: ownerID)
                    guard scheduled < count else { return true }
                    state.barriers[id] = Barrier(
                        ownerID: ownerID,
                        minimumCount: count,
                        continuation: continuation
                    )
                    return false
                }
                if resumeNow { continuation.resume(returning: !Task.isCancelled) }
            }
        } onCancel: {
            let continuation = storage.withLock { state -> CheckedContinuation<Bool, Never>? in
                if let barrier = state.barriers.removeValue(forKey: id) {
                    return barrier.continuation
                }
                state.cancelledBarriers.insert(id)
                return nil
            }
            continuation?.resume(returning: false)
        }
    }

    /// Advances virtual time and resumes every due sleeper exactly once.
    public func advance(by duration: Duration) {
        let interval = Self.timeInterval(for: duration)
        let continuations = storage.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.now = state.now.addingTimeInterval(interval)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return due.values.map(\.continuation)
        }
        continuations.forEach { $0.resume() }
    }

    /// Cancels every outstanding virtual sleep owned by this clock.
    public func cancelAll() {
        let result = storage.withLock { state -> (
            [CheckedContinuation<Void, any Error>],
            [CheckedContinuation<Bool, Never>]
        ) in
            let sleepers = state.sleepers.values.map(\.continuation)
            let barriers = state.barriers.values.map(\.continuation)
            state.sleepers.removeAll(keepingCapacity: false)
            state.barriers.removeAll(keepingCapacity: false)
            state.cancelledBarriers.removeAll(keepingCapacity: false)
            return (sleepers, barriers)
        }
        result.0.forEach { $0.resume(throwing: CancellationError()) }
        result.1.forEach { $0.resume(returning: false) }
    }

    package func cancelAll(ownerID: UUID) {
        let result = storage.withLock { state -> (
            [CheckedContinuation<Void, any Error>],
            [CheckedContinuation<Bool, Never>]
        ) in
            let owned = state.sleepers.filter { $0.value.ownerID == ownerID }
            for id in owned.keys { state.sleepers.removeValue(forKey: id) }
            let barriers = state.barriers.filter { $0.value.ownerID == ownerID }
            for id in barriers.keys { state.barriers.removeValue(forKey: id) }
            return (owned.values.map(\.continuation), barriers.values.map(\.continuation))
        }
        result.0.forEach { $0.resume(throwing: CancellationError()) }
        result.1.forEach { $0.resume(returning: false) }
    }

    package func sleep(for duration: Duration, ownerID: UUID) async throws {
        if duration <= .zero { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let result = storage.withLock { state -> (Bool, [CheckedContinuation<Bool, Never>]) in
                    let deadline = state.now.addingTimeInterval(Self.timeInterval(for: duration))
                    guard deadline > state.now else { return (true, []) }
                    state.sleepers[id] = Sleeper(
                        ownerID: ownerID,
                        deadline: deadline,
                        continuation: continuation
                    )
                    let ready = state.barriers.filter {
                        Self.scheduledCount(in: state, ownerID: $0.value.ownerID)
                            >= $0.value.minimumCount
                    }
                    for id in ready.keys { state.barriers.removeValue(forKey: id) }
                    return (false, ready.values.map(\.continuation))
                }
                result.1.forEach { $0.resume(returning: true) }
                if result.0 { continuation.resume() }
            }
        } onCancel: {
            let continuation = storage.withLock { state in
                state.sleepers.removeValue(forKey: id)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }

    private func scheduledCount(ownerID: UUID?) -> Int {
        storage.withLock { Self.scheduledCount(in: $0, ownerID: ownerID) }
    }

    private static func scheduledCount(in state: State, ownerID: UUID?) -> Int {
        guard let ownerID else { return state.sleepers.count }
        return state.sleepers.values.reduce(into: 0) { count, sleeper in
            if sleeper.ownerID == ownerID { count += 1 }
        }
    }
}

/// Deterministic time and transition identity supplied to a `RouterTestStore`.
public final class RouterTestRuntime: Sendable {
    public let clock: RouterTestClock

    private let sequence: Mutex<UInt64>

    public init(
        clock: RouterTestClock = RouterTestClock(),
        transitionIDSeed: UInt64 = 1
    ) {
        self.clock = clock
        self.sequence = Mutex(transitionIDSeed)
    }

    package func nextTransitionID() -> RouterTransitionID {
        let current = sequence.withLock { nextSequence -> UInt64 in
            let value = nextSequence
            precondition(value < UInt64.max, "RouterTestRuntime exhausted transition IDs")
            nextSequence &+= 1
            return value
        }
        let suffix = String(format: "%012llX", current)
        guard let value = UUID(uuidString: "60000000-0000-0000-0000-\(suffix)") else {
            preconditionFailure("RouterTestRuntime generated an invalid transition UUID")
        }
        return RouterTransitionID(rawValue: value)
    }

    package func dependencies(ownerID: UUID) -> RouterRuntimeDependencies {
        RouterRuntimeDependencies(
            now: { [clock] in clock.now },
            sleep: { [clock] duration in
                try await clock.sleep(for: duration, ownerID: ownerID)
            },
            makeTransitionID: { [weak self] in
                self?.nextTransitionID() ?? RouterTransitionID()
            }
        )
    }
}
