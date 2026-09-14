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
    public package(set) var lastRestorationReport: RouterPartialRestorationReport?

    public let capacity: Int
    public let checkpointCapacity: Int

    @ObservationIgnored
    package let store: RouterStore<R>
    @ObservationIgnored
    package let validator: RouterPartialRestorationValidator<R>?
    @ObservationIgnored
    package let validationTimeout: Duration?
    @ObservationIgnored
    private var eventObserverID: UUID?
    @ObservationIgnored
    private var recordWaiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
    @ObservationIgnored
    private var revisionWaiters: [UUID: (revision: UInt64, continuation: CheckedContinuation<Bool, Never>)] = [:]
    @ObservationIgnored
    package var isStopped = false
    @ObservationIgnored
    private var latestObservedRevision: UInt64
    @ObservationIgnored
    package var generation: UInt64 = 0
    @ObservationIgnored
    package var pendingMoves: [RouterDeferralID: PendingRouterHistoryMove<R>] = [:]
    @ObservationIgnored
    private var activeMoves: [UUID: ActiveRouterHistoryMove<R>] = [:]
    @ObservationIgnored
    package var activeMoveRequestRoots: [UUID: RouterTransitionID] = [:]
    @ObservationIgnored
    package var ownedRequestRoots: Set<RouterTransitionID> = []
    @ObservationIgnored
    package var activeRequestMoves: [RouterTransitionID: PendingRouterHistoryMove<R>] = [:]
    @ObservationIgnored
    package var activeRequestTerminalWaiters: [
        RouterTransitionID: CheckedContinuation<Void, Never>
    ] = [:]

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
        await waitUntilRecorded(count, didSuspend: {})
    }

    package func waitUntilRecorded(
        _ count: Int,
        didSuspend: @MainActor @Sendable () -> Void
    ) async -> Bool {
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
                didSuspend()
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
        return await runMove(checkpoint.entry, destinationCursor: nil)
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
        activeRequestMoves.removeAll()
        let terminalWaiters = activeRequestTerminalWaiters.values
        activeRequestTerminalWaiters.removeAll()
        terminalWaiters.forEach { $0.resume() }
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
            activeRequestMoves.removeValue(forKey: requestRootID)
            activeRequestTerminalWaiters.removeValue(forKey: requestRootID)?.resume()
            ownedRequestRoots.remove(requestRootID)
            store.cancelRequestFamily(requestRootID)
        }
        move.continuation.resume(returning: .unavailable(cursor: cursor, reason: reason))
    }
}

private extension RouterHistory {
    private func observe(_ event: RouterEvent<R>) {
        guard !isStopped else { return }
        registerActiveMoveAsDeferredIfNeeded(for: event)
        let isOwnedHistoryCommit = Self.ownsHistoryCommit(
            event,
            ownedRequestRoots: ownedRequestRoots,
            pendingMoves: pendingMoves
        )
        completeActiveMoveIfNeeded(for: event)
        if let completedMove = Self.updatePendingMoveOwnership(
            for: event,
            generation: generation,
            pendingMoves: &pendingMoves,
            ownedRequestRoots: &ownedRequestRoots
        ) {
            if let terminal = event.historyTerminalState {
                completePendingMove(
                    completedMove,
                    state: terminal.state,
                    revision: terminal.revision
                )
            }
        }
        guard case .committed(_, _, let after, let revision, let context) = event,
              revision > latestObservedRevision else { return }
        latestObservedRevision = revision
        resumeRevisionWaiters(through: revision)
        let projection = Self.navigationProjection(after)
        if context.source == .history, !isOwnedHistoryCommit,
           let destination = Self.nearestEntry(
               in: entries,
               from: cursor,
               matching: projection
           ) {
            cursor = destination
            return
        }
        guard !isOwnedHistoryCommit else { return }
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
        resumeRecordWaitersIfNeeded()
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

    private func completeActiveMoveIfNeeded(for event: RouterEvent<R>) {
        guard let terminal = event.historyTerminalState,
              event.transitionContext?.source == .history,
              let transitionID = event.transitionID,
              let pending = activeRequestMoves.removeValue(forKey: transitionID) else {
            return
        }
        ownedRequestRoots.remove(pending.requestRootID)
        if pending.generation == generation {
            completePendingMove(
                pending,
                state: terminal.state,
                revision: terminal.revision
            )
        }
        activeRequestTerminalWaiters.removeValue(forKey: transitionID)?.resume()
    }

    private func registerActiveMoveAsDeferredIfNeeded(for event: RouterEvent<R>) {
        guard case .deferred(
            let transitionID,
            _,
            _,
            let deferral,
            let context
        ) = event,
        context.source == .history,
        context.resumedDeferral == nil,
        let pending = activeRequestMoves.removeValue(forKey: transitionID) else {
            return
        }
        pendingMoves[deferral.id] = pending
    }

    private func completePendingMove(
        _ pending: PendingRouterHistoryMove<R>,
        state: RouterState<R>,
        revision: UInt64
    ) {
        let normalized = RouterHistoryEntry(
            id: pending.entry.id,
            navigationState: Self.navigationProjection(state),
            sourceRevision: revision
        )
        if let destination = pending.destinationCursor,
           entries.indices.contains(destination),
           entries[destination].id == pending.entry.id {
            entries[destination] = normalized
            cursor = destination
            resumeRecordWaitersIfNeeded()
            return
        }
        if let existing = entries.firstIndex(where: { $0.id == pending.entry.id }) {
            entries[existing] = normalized
            cursor = existing
            resumeRecordWaitersIfNeeded()
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
        resumeRecordWaitersIfNeeded()
    }

    private func resumeRecordWaitersIfNeeded() {
        let ready = recordWaiters.filter { entries.count >= $0.value.count }
        for id in ready.keys { recordWaiters.removeValue(forKey: id) }
        ready.values.forEach { $0.continuation.resume(returning: true) }
    }
}

public extension RouterHistory {
    func removeAllCheckpoints() {
        checkpoints.removeAll()
    }
}
