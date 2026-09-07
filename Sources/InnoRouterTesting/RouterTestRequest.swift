// MARK: - RouterTestRequest.swift
// InnoRouterTesting - controllable concurrent request handles
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// Snapshot of work that must be resolved before a strict test-store finish.
public struct RouterTestPendingWork: Hashable, Sendable {
    public let requests: Int
    public let deferrals: Int
    public let timers: Int
    public let waiters: Int

    public init(requests: Int, deferrals: Int, timers: Int, waiters: Int = 0) {
        self.requests = requests
        self.deferrals = deferrals
        self.timers = timers
        self.waiters = waiters
    }

    public var isEmpty: Bool {
        requests == 0 && deferrals == 0 && timers == 0 && waiters == 0
    }
}

@MainActor
final class RouterTestRequestLifecycle<R: Route> {
    private struct StartWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct EventWaiter {
        let predicate: (RouterEvent<R>) -> Bool
        let continuation: CheckedContinuation<RouterEvent<R>?, Never>
    }

    private var started: Set<RouterTransitionID> = []
    private var queued: Set<RouterTransitionID> = []
    private var terminal: Set<RouterTransitionID> = []
    private var tasks: [RouterTransitionID: Task<RouterOutcome<R>, Never>] = [:]
    private var startWaiters: [RouterTransitionID: [StartWaiter]] = [:]
    private var queueWaiters: [RouterTransitionID: [StartWaiter]] = [:]
    private var recentEvents: [RouterEvent<R>] = []
    private var eventWaiters: [UUID: EventWaiter] = [:]
    private var waiterCountBarriers: [(Int, CheckedContinuation<Void, Never>)] = []

    var pendingRequestCount: Int { tasks.count }
    var pendingWaiterCount: Int {
        eventWaiters.count
            + startWaiters.values.reduce(into: 0) { $0 += $1.count }
            + queueWaiters.values.reduce(into: 0) { $0 += $1.count }
    }

    func register(
        id: RouterTransitionID,
        task: Task<RouterOutcome<R>, Never>
    ) {
        tasks[id] = task
    }

    func observe(_ event: RouterEvent<R>) {
        recentEvents.append(event)
        if recentEvents.count > 1_024 {
            recentEvents.removeFirst(recentEvents.count - 1_024)
        }
        let matching = eventWaiters.filter { $0.value.predicate(event) }
        for id in matching.keys { eventWaiters.removeValue(forKey: id) }
        matching.values.forEach { $0.continuation.resume(returning: event) }

        switch event {
        case .started(let transition):
            started.insert(transition.id)
            resumeStartWaiters(for: transition.id, value: true)
            if queued.contains(transition.id) == false {
                resumeQueueWaiters(for: transition.id, value: false)
            }
        case .committed(let id, _, _, _, _),
             .unchanged(let id, _, _, _),
             .deferred(let id, _, _, _, _),
             .rejected(let id, _, _, _, _):
            terminal.insert(id)
            tasks.removeValue(forKey: id)
            if started.contains(id) == false {
                resumeStartWaiters(for: id, value: false)
            }
            if queued.contains(id) == false {
                resumeQueueWaiters(for: id, value: false)
            }
        case .policyPrepared, .platformAdapted:
            break
        }
    }

    func observeQueued(_ id: RouterTransitionID) {
        queued.insert(id)
        let waiters = queueWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.continuation.resume(returning: true) }
    }

    func waitForEvent(
        matching predicate: @escaping (RouterEvent<R>) -> Bool
    ) async -> RouterEvent<R>? {
        if let event = recentEvents.first(where: predicate) { return event }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                eventWaiters[id] = EventWaiter(
                    predicate: predicate,
                    continuation: continuation
                )
                resumeWaiterCountBarriers()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelEventWaiter(id)
            }
        }
    }

    func waitUntilStarted(_ id: RouterTransitionID) async -> Bool {
        if started.contains(id) { return true }
        if terminal.contains(id) { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                startWaiters[id, default: []].append(StartWaiter(
                    id: waiterID,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelStartWaiter(waiterID, transitionID: id)
            }
        }
    }

    func waitUntilQueued(_ id: RouterTransitionID) async -> Bool {
        if queued.contains(id) { return true }
        if started.contains(id) || terminal.contains(id) { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                queueWaiters[id, default: []].append(StartWaiter(
                    id: waiterID,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueueWaiter(waiterID, transitionID: id)
            }
        }
    }

    @discardableResult
    func cancelAll() -> [Task<RouterOutcome<R>, Never>] {
        let values = Array(tasks.values)
        tasks.removeAll(keepingCapacity: false)
        values.forEach { $0.cancel() }
        for (id, waiters) in startWaiters {
            if started.contains(id) == false {
                waiters.forEach { $0.continuation.resume(returning: false) }
            }
        }
        startWaiters.removeAll(keepingCapacity: false)
        for waiters in queueWaiters.values {
            waiters.forEach { $0.continuation.resume(returning: false) }
        }
        queueWaiters.removeAll(keepingCapacity: false)
        let pendingEventWaiters = Array(eventWaiters.values)
        eventWaiters.removeAll(keepingCapacity: false)
        pendingEventWaiters.forEach { $0.continuation.resume(returning: nil) }
        let barriers = waiterCountBarriers
        waiterCountBarriers.removeAll(keepingCapacity: false)
        barriers.forEach { $0.1.resume() }
        return values
    }

    func waitUntilWaiterCount(_ minimumCount: Int) async {
        if pendingWaiterCount >= minimumCount { return }
        await withCheckedContinuation { continuation in
            waiterCountBarriers.append((minimumCount, continuation))
        }
    }

    private func cancelEventWaiter(_ id: UUID) {
        eventWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }

    private func cancelStartWaiter(_ waiterID: UUID, transitionID: RouterTransitionID) {
        cancelWaiter(waiterID, transitionID: transitionID, in: &startWaiters)
    }

    private func cancelQueueWaiter(_ waiterID: UUID, transitionID: RouterTransitionID) {
        cancelWaiter(waiterID, transitionID: transitionID, in: &queueWaiters)
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        transitionID: RouterTransitionID,
        in storage: inout [RouterTransitionID: [StartWaiter]]
    ) {
        guard var waiters = storage[transitionID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            storage.removeValue(forKey: transitionID)
        } else {
            storage[transitionID] = waiters
        }
        waiter.continuation.resume(returning: false)
    }

    private func resumeWaiterCountBarriers() {
        let ready = waiterCountBarriers.filter { pendingWaiterCount >= $0.0 }
        waiterCountBarriers.removeAll { pendingWaiterCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeStartWaiters(for id: RouterTransitionID, value: Bool) {
        let waiters = startWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.continuation.resume(returning: value) }
    }

    private func resumeQueueWaiters(for id: RouterTransitionID, value: Bool) {
        let waiters = queueWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.continuation.resume(returning: value) }
    }
}

/// One concurrently running request started by `RouterTestStore.start`.
@MainActor
public final class RouterTestRequest<R: Route> {
    public let id: RouterTransitionID

    private let task: Task<RouterOutcome<R>, Never>
    private let lifecycle: RouterTestRequestLifecycle<R>

    init(
        id: RouterTransitionID,
        task: Task<RouterOutcome<R>, Never>,
        lifecycle: RouterTestRequestLifecycle<R>
    ) {
        self.id = id
        self.task = task
        self.lifecycle = lifecycle
    }

    /// Waits for the production pipeline's `.started` event. Returns `false`
    /// when the request is rejected before entering that lifecycle phase.
    public func waitUntilStarted() async -> Bool {
        await lifecycle.waitUntilStarted(id)
    }

    /// Waits until the request enters the serialized pending queue. Returns
    /// `false` if it starts or terminates without being queued.
    public func waitUntilQueued() async -> Bool {
        await lifecycle.waitUntilQueued(id)
    }

    /// Waits for the exact terminal outcome.
    public var result: RouterOutcome<R> {
        get async { await task.value }
    }

    /// Cancels only this request.
    public func cancel() {
        task.cancel()
    }
}
