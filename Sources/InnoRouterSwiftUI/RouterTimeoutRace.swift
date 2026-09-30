// MARK: - RouterTimeoutRace.swift
// InnoRouterSwiftUI - shared timeout/cancellation race
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Outcome of racing an operation against a timeout and caller cancellation.
enum RouterTimeoutRaceResult<Value: Sendable>: Sendable {
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
@MainActor
final class RouterTimeoutRace<Value: Sendable> {
    private var continuation: CheckedContinuation<RouterTimeoutRaceResult<Value>, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        timeout: Duration?,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) async -> RouterTimeoutRaceResult<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    resolve(.cancelled)
                    return
                }
                operationTask = Task { @MainActor [weak self] in
                    let value = await operation()
                    self?.resolve(.value(value))
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
                self?.resolve(.cancelled)
            }
        }
    }

    /// Resolves the race as cancelled if it has not already finished.
    func cancel() {
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
