// MARK: - RouterTimeoutRace.swift
// InnoRouterCore - shared timeout/cancellation race
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Outcome of racing an operation against a timeout and caller cancellation.
package enum RouterTimeoutRaceResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
}

/// Runs one operation against an optional timeout, resolving exactly once.
///
/// Policy preparation and partial restoration each had their own copy of this,
/// identical down to the `weak self` captures and the resolve-once bookkeeping.
/// Two hand-written copies of a concurrency primitive are a correctness hazard
/// rather than a line-count one: a fix applied to one copy silently leaves the
/// other wrong. This is the single implementation both now use.
///
/// `resolve` is the only path that finishes the continuation, and it clears the
/// stored continuation first, so a timeout firing next to a completing
/// operation — or next to caller cancellation — still resumes exactly once.
///
/// When passed a registry reservation, logical completion cancels the task but
/// the registry retains its handle until the operation actually exits. The
/// operation captures this race weakly and cannot deliver a second result.
@MainActor
package final class RouterTimeoutRace<Value: Sendable> {
    private var continuation: CheckedContinuation<RouterTimeoutRaceResult<Value>, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private var hasStarted = false
    private var cancelledBeforeStart = false

    package init() {}

    package func run(
        timeout: Duration?,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        reservation: RouterOperationRegistry.Reservation? = nil,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> RouterTimeoutRaceResult<Value> {
        precondition(!hasStarted, "A timeout race can only run once")
        hasStarted = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled, !cancelledBeforeStart else {
                    reservation?.abandonBeforeStart()
                    resolve(.cancelled)
                    return
                }
                let perform: @MainActor @Sendable () async -> Void = { [weak self] in
                    guard !Task.isCancelled else {
                        self?.resolve(.cancelled)
                        return
                    }
                    let value = await operation()
                    self?.resolve(.value(value))
                }
                if let reservation {
                    operationTask = reservation.start(perform)
                } else {
                    operationTask = Task { @MainActor in await perform() }
                }
                if let timeout {
                    timeoutTask = Task { @MainActor [weak self] in
                        do {
                            try await sleep(timeout)
                        } catch {
                            return
                        }
                        self?.resolve(.timedOut)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    /// Resolves the race as cancelled if it has not already finished.
    package func cancel() {
        if !hasStarted { cancelledBeforeStart = true }
        resolve(.cancelled)
    }

    private func resolve(_ result: RouterTimeoutRaceResult<Value>) {
        guard let continuation else { return }
        self.continuation = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume(returning: result)
    }
}
