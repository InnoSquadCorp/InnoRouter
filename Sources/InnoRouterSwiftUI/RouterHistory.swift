import Foundation
import Observation

import InnoRouterCore

/// Opt-in, bounded navigation history backed by one canonical `RouterStore`.
///
/// Entries retain stack paths and container selection/split state. Applying an
/// entry merges those values into the current scenes, preserving badges and
/// presentations and never opening or closing a scene.
@MainActor
@Observable
public final class RouterHistory<R: Route> {
    public private(set) var entries: [RouterHistoryEntry<R>]
    public private(set) var cursor: Int
    public private(set) var checkpoints: [RouterHistoryCheckpoint<R>] = []
    public private(set) var sessionKey: String
    public private(set) var lastRestorationReport: RouterPartialRestorationReport?

    public let capacity: Int
    public let checkpointCapacity: Int

    @ObservationIgnored
    private let store: RouterStore<R>
    @ObservationIgnored
    private let validator: RouterPartialRestorationValidator<R>?
    @ObservationIgnored
    private let validationTimeout: Duration?
    @ObservationIgnored
    private var eventObserverID: UUID?
    @ObservationIgnored
    private var recordWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    @ObservationIgnored
    private var revisionWaiters: [UUID: (revision: UInt64, continuation: CheckedContinuation<Bool, Never>)] = [:]
    @ObservationIgnored
    private var isStopped = false
    @ObservationIgnored
    private var latestObservedRevision: UInt64
    @ObservationIgnored
    private var generation: UInt64 = 0
    @ObservationIgnored
    private var pendingMoves: [RouterDeferralID: PendingRouterHistoryMove<R>] = [:]
    @ObservationIgnored
    private var activeMoves: [UUID: ActiveRouterHistoryMove<R>] = [:]
    @ObservationIgnored
    private var activeMoveRequestRoots: [UUID: RouterTransitionID] = [:]
    @ObservationIgnored
    private var ownedRequestRoots: Set<RouterTransitionID> = []

    public init(
        store: RouterStore<R>,
        configuration: RouterHistoryConfiguration = .init(),
        validator: RouterPartialRestorationValidator<R>? = nil,
        validationTimeout: Duration? = nil
    ) {
        self.store = store
        self.validator = validator
        self.validationTimeout = validationTimeout
        self.capacity = configuration.capacity
        self.checkpointCapacity = configuration.checkpointCapacity
        self.sessionKey = configuration.sessionKey
        self.entries = [
            .init(
                navigationState: Self.navigationProjection(store.state),
                sourceRevision: store.revision
            ),
        ]
        self.cursor = 0
        self.lastRestorationReport = nil
        self.latestObservedRevision = store.revision
        eventObserverID = store.addSynchronousEventObserver { [weak self] event in
            self?.observe(event)
        }
    }

    // Work around swiftlang/swift#90625 in Swift 6.3.x release builds.
    #if compiler(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        cancelOwnedOperations(reason: .stopped)
        pendingMoves.removeAll()
        if let eventObserverID {
            store.removeSynchronousEventObserver(eventObserverID)
        }
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
        cancelOwnedOperations(reason: .stopped)
        pendingMoves.removeAll()
        if let eventObserverID {
            store.removeSynchronousEventObserver(eventObserverID)
            self.eventObserverID = nil
        }
        let waiters = recordWaiters.values
        recordWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: false) }
        let pendingRevisionWaiters = revisionWaiters.values
        revisionWaiters.removeAll()
        pendingRevisionWaiters.forEach { $0.continuation.resume(returning: false) }
    }

    public func waitUntilRecorded(_ count: Int) async -> Bool {
        if entries.count >= count { return true }
        guard !isStopped else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isStopped else {
                    continuation.resume(returning: false)
                    return
                }
                recordWaiters[id] = (max(0, count), continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRecordWaiter(id) }
        }
    }

    /// Suspends until a committed transition with at least `revision` has
    /// been observed, even when it does not create a history entry.
    public func waitUntilRecordedRevision(_ revision: UInt64) async -> Bool {
        if latestObservedRevision >= revision { return true }
        guard !isStopped else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isStopped else {
                    continuation.resume(returning: false)
                    return
                }
                revisionWaiters[id] = (revision, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRevisionWaiter(id) }
        }
    }

    @discardableResult
    public func goBack() async -> RouterHistoryMoveResult<R> {
        guard !isStopped else {
            return .unavailable(cursor: cursor, reason: .stopped)
        }
        guard canGoBack else {
            return .unavailable(cursor: cursor, reason: .noPreviousEntry)
        }
        return await move(to: cursor - 1)
    }

    @discardableResult
    public func goForward() async -> RouterHistoryMoveResult<R> {
        guard !isStopped else {
            return .unavailable(cursor: cursor, reason: .stopped)
        }
        guard canGoForward else {
            return .unavailable(cursor: cursor, reason: .noNextEntry)
        }
        return await move(to: cursor + 1)
    }

    @discardableResult
    public func createCheckpoint(
        named name: String,
        collision: RouterHistoryCheckpointCollisionStrategy = .reject
    ) -> Result<RouterHistoryCheckpoint<R>, RouterHistoryFailure> {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidCheckpointName)
        }
        if let index = checkpoints.firstIndex(where: { $0.name == name }) {
            guard collision == .replace else {
                return .failure(.checkpointAlreadyExists(name))
            }
            let replacement = RouterHistoryCheckpoint(
                name: name,
                sessionKey: sessionKey,
                entry: currentEntry
            )
            checkpoints[index] = replacement
            return .success(replacement)
        }
        guard checkpoints.count < checkpointCapacity else {
            return .failure(.checkpointCapacityExceeded(limit: checkpointCapacity))
        }
        let checkpoint = RouterHistoryCheckpoint(
            name: name,
            sessionKey: sessionKey,
            entry: currentEntry
        )
        checkpoints.append(checkpoint)
        return .success(checkpoint)
    }

    @discardableResult
    public func restoreCheckpoint(named name: String) async -> RouterHistoryMoveResult<R> {
        guard !isStopped else {
            return .unavailable(cursor: cursor, reason: .stopped)
        }
        guard let checkpoint = checkpoints.first(where: { $0.name == name }) else {
            return .unavailable(cursor: cursor, reason: .checkpointNotFound(name))
        }
        guard checkpoint.sessionKey == sessionKey else {
            return .unavailable(
                cursor: cursor,
                reason: .sessionMismatch(expected: sessionKey, actual: checkpoint.sessionKey)
            )
        }
        let result = await runMove(checkpoint.entry, destinationCursor: nil)
        guard case .completed(_, let transition) = result else { return result }
        if let existing = entries.firstIndex(where: { $0.id == checkpoint.entry.id }) {
            entries[existing] = .init(
                id: checkpoint.entry.id,
                navigationState: Self.navigationProjection(store.state),
                sourceRevision: store.revision
            )
            cursor = existing
        } else {
            if cursor + 1 < entries.endIndex {
                entries.removeSubrange((cursor + 1)..<entries.endIndex)
            }
            entries.append(.init(
                id: checkpoint.entry.id,
                navigationState: Self.navigationProjection(store.state),
                sourceRevision: store.revision
            ))
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
            cursor = entries.index(before: entries.endIndex)
        }
        return .completed(cursor: cursor, transition: transition)
    }

    @discardableResult
    public func removeCheckpoint(named name: String) -> Bool {
        guard let index = checkpoints.firstIndex(where: { $0.name == name }) else {
            return false
        }
        checkpoints.remove(at: index)
        return true
    }

    /// Imports one app-decoded checkpoint after version, session, duplicate,
    /// and capacity validation. Storage location remains app-owned.
    @discardableResult
    public func importCheckpoint(
        _ checkpoint: RouterHistoryCheckpoint<R>,
        collision: RouterHistoryCheckpointCollisionStrategy = .reject
    ) -> Result<RouterHistoryCheckpoint<R>, RouterHistoryFailure> {
        guard checkpoint.formatVersion == 1 else {
            return .failure(.unsupportedCheckpointVersion(checkpoint.formatVersion))
        }
        guard checkpoint.sessionKey == sessionKey else {
            return .failure(.sessionMismatch(
                expected: sessionKey,
                actual: checkpoint.sessionKey
            ))
        }
        guard !checkpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidCheckpointName)
        }
        if let index = checkpoints.firstIndex(where: { $0.name == checkpoint.name }) {
            guard collision == .replace else {
                return .failure(.checkpointAlreadyExists(checkpoint.name))
            }
            checkpoints[index] = checkpoint
            return .success(checkpoint)
        }
        guard checkpoints.count < checkpointCapacity else {
            return .failure(.checkpointCapacityExceeded(limit: checkpointCapacity))
        }
        checkpoints.append(checkpoint)
        return .success(checkpoint)
    }

    /// Starts a new app-owned session boundary and discards every old route.
    public func reset(sessionKey: String) {
        generation &+= 1
        cancelOwnedOperations(reason: .cancelled)
        pendingMoves.removeAll()
        self.sessionKey = sessionKey
        checkpoints.removeAll()
        entries = [
            .init(
                navigationState: Self.navigationProjection(store.state),
                sourceRevision: store.revision
            ),
        ]
        cursor = 0
        latestObservedRevision = store.revision
        resumeRevisionWaiters(through: latestObservedRevision)
    }

    private func move(to destination: Int) async -> RouterHistoryMoveResult<R> {
        await runMove(entries[destination], destinationCursor: destination)
    }

    private func runMove(
        _ entry: RouterHistoryEntry<R>,
        destinationCursor: Int?
    ) async -> RouterHistoryMoveResult<R> {
        let operationID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !isStopped else {
                    continuation.resume(returning: .unavailable(
                        cursor: cursor,
                        reason: Task.isCancelled ? .cancelled : .stopped
                    ))
                    return
                }
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = await self.apply(
                        entry,
                        destinationCursor: destinationCursor,
                        operationID: operationID
                    )
                    self.finishMove(operationID, with: result)
                }
                activeMoves[operationID] = .init(
                    task: task,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelMove(operationID, reason: .cancelled)
            }
        }
    }

    private func cancelOwnedOperations(reason: RouterHistoryFailure) {
        let moves = activeMoves
        activeMoves.removeAll()
        for move in moves.values {
            move.task.cancel()
            move.continuation.resume(returning: .unavailable(
                cursor: cursor,
                reason: reason
            ))
        }
        let roots = ownedRequestRoots
        ownedRequestRoots.removeAll()
        activeMoveRequestRoots.removeAll()
        roots.forEach(store.cancelRequestFamily)
    }

    private func finishMove(
        _ operationID: UUID,
        with result: RouterHistoryMoveResult<R>
    ) {
        activeMoveRequestRoots.removeValue(forKey: operationID)
        activeMoves.removeValue(forKey: operationID)?.continuation.resume(returning: result)
    }

    private func cancelMove(
        _ operationID: UUID,
        reason: RouterHistoryFailure
    ) {
        guard let move = activeMoves.removeValue(forKey: operationID) else { return }
        move.task.cancel()
        if let requestRootID = activeMoveRequestRoots.removeValue(forKey: operationID) {
            ownedRequestRoots.remove(requestRootID)
            store.cancelRequestFamily(requestRootID)
        }
        move.continuation.resume(returning: .unavailable(cursor: cursor, reason: reason))
    }

    private func observe(_ event: RouterEvent<R>) {
        guard !isStopped else { return }
        if let context = event.transitionContext,
           context.source == .history,
           let deferralID = context.resumedDeferral {
            switch event {
            case .committed, .unchanged:
                if let pending = pendingMoves.removeValue(forKey: deferralID),
                   pending.generation == generation {
                    ownedRequestRoots.remove(pending.requestRootID)
                    completePendingMove(pending)
                }
            case .deferred(_, _, _, let deferral, _):
                if let pending = pendingMoves.removeValue(forKey: deferralID),
                   pending.generation == generation {
                    pendingMoves[deferral.id] = pending
                }
            case .rejected:
                if let pending = pendingMoves.removeValue(forKey: deferralID) {
                    ownedRequestRoots.remove(pending.requestRootID)
                }
            default:
                break
            }
        }
        guard case .committed(_, _, let after, let revision, let context) = event,
              revision > latestObservedRevision else { return }
        latestObservedRevision = revision
        resumeRevisionWaiters(through: revision)
        guard context.source != .history else { return }
        let projection = Self.navigationProjection(after)
        guard !Self.hasSameNavigation(projection, entries[cursor].navigationState) else {
            return
        }
        if cursor + 1 < entries.endIndex {
            entries.removeSubrange((cursor + 1)..<entries.endIndex)
        }
        entries.append(.init(navigationState: projection, sourceRevision: revision))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        cursor = entries.index(before: entries.endIndex)
        let ready = recordWaiters.filter { entries.count >= $0.value.count }
        for id in ready.keys { recordWaiters.removeValue(forKey: id) }
        ready.values.forEach { $0.continuation.resume(returning: true) }
    }

    private func resumeRevisionWaiters(through revision: UInt64) {
        let ready = revisionWaiters.filter { revision >= $0.value.revision }
        for id in ready.keys { revisionWaiters.removeValue(forKey: id) }
        ready.values.forEach { $0.continuation.resume(returning: true) }
    }

    private func cancelRecordWaiter(_ id: UUID) {
        recordWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    private func cancelRevisionWaiter(_ id: UUID) {
        revisionWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    private func completePendingMove(_ pending: PendingRouterHistoryMove<R>) {
        let normalized = RouterHistoryEntry(
            id: pending.entry.id,
            navigationState: Self.navigationProjection(store.state),
            sourceRevision: store.revision
        )
        if let destination = pending.destinationCursor,
           entries.indices.contains(destination),
           entries[destination].id == pending.entry.id {
            entries[destination] = normalized
            cursor = destination
            return
        }
        if let existing = entries.firstIndex(where: { $0.id == pending.entry.id }) {
            entries[existing] = normalized
            cursor = existing
            return
        }
        if cursor + 1 < entries.endIndex {
            entries.removeSubrange((cursor + 1)..<entries.endIndex)
        }
        entries.append(normalized)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        cursor = entries.index(before: entries.endIndex)
    }
}

public extension RouterHistory {
    var canGoBack: Bool { cursor > entries.startIndex }
    var canGoForward: Bool { cursor + 1 < entries.endIndex }
    var currentEntry: RouterHistoryEntry<R> { entries[cursor] }

    func removeAllCheckpoints() {
        checkpoints.removeAll()
    }
}

private extension RouterHistory {
    func apply(
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
            ownedRequestRoots.remove(requestRootID)
            if let destinationCursor,
               generation == startingGeneration,
               entries.indices.contains(destinationCursor),
               entries[destinationCursor].id == entry.id {
                cursor = destinationCursor
                entries[destinationCursor] = .init(
                    id: entry.id,
                    navigationState: Self.navigationProjection(store.state),
                    sourceRevision: store.revision
                )
            }
            return .completed(cursor: cursor, transition: outcome)
        case .deferred(_, _, _, let deferral):
            pendingMoves[deferral.id] = .init(
                generation: startingGeneration,
                requestRootID: requestRootID,
                entry: entry,
                destinationCursor: destinationCursor
            )
            return .deferred(cursor: cursor, transition: outcome)
        case .rejected:
            ownedRequestRoots.remove(requestRootID)
            return .rejected(cursor: cursor, transition: outcome)
        }
    }
}
