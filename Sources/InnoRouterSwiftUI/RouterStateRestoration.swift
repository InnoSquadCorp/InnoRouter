// MARK: - RouterStateRestoration.swift
// InnoRouterSwiftUI - opt-in snapshot transport and scene lifecycle driver
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation

import InnoRouterCore

private struct RouterRestorationActivationLease<R: Route & Codable> {
    let result: RouterRestorationDriverActivation<R>
    let generation: UInt64
}

private struct RouterRestorationPartialConfiguration<R: Route> {
    let validator: RouterPartialRestorationValidator<R>
    let validationTimeout: Duration?
}

/// Opt-in automatic persistence for one canonical router store.
///
/// The driver observes committed transitions, coalesces writes, and restores
/// through the normal policy pipeline. It never becomes another state owner;
/// storage contains only snapshots produced by the supplied codec.
@MainActor
@Observable
public final class RouterRestorationDriver<R: Route & Codable> {
    /// Status belongs to the most recently started activation, save, removal,
    /// or stop. Debounce reservations and already-active claims do not replace
    /// it; older operations still finish and return their own results.
    public private(set) var status: RouterRestorationDriverStatus = .inactive
    public private(set) var lastActivation: RouterRestorationDriverActivation<R>?
    /// Report and transition returned by the latest partial activation.
    ///
    /// A deferred transition is not a terminal success. Observe Store events
    /// for the final resumed outcome.
    public private(set) var lastPartialRestoration: RouterPartialRestorationOutcome<R>?

    @ObservationIgnored
    package let durability = RouterDurabilityGate()
    @ObservationIgnored
    package let store: RouterStore<R>
    @ObservationIgnored
    private let codec: RouterSnapshotCodec<R>
    @ObservationIgnored
    private let recovery: RouterSnapshotRecoveryPolicy<R>
    @ObservationIgnored
    package let executor: RouterByteStoreExecutor
    @ObservationIgnored
    package let codecExecutor: RouterSnapshotCodecExecutor<R>
    @ObservationIgnored
    package let saveDebounce: Duration
    @ObservationIgnored
    private var observationID: UUID?
    @ObservationIgnored
    package var scheduledSaveTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeRestoreTransitionID: RouterTransitionID?
    @ObservationIgnored
    private var activeRestoreRequestRootID: RouterTransitionID?
    @ObservationIgnored
    private var activeRestoreDeferralID: RouterDeferralID?
    @ObservationIgnored
    private var attachmentIDs: Set<UUID> = []
    @ObservationIgnored
    private var retainsManualActivation = false
    @ObservationIgnored
    private var pendingManualActivationIDs: Set<UUID> = []
    @ObservationIgnored
    private var activationTask: Task<Void, Never>?
    @ObservationIgnored
    private var activationTaskID: UUID?
    @ObservationIgnored
    private var activationWaiters: [
        UUID: CheckedContinuation<RouterRestorationActivationLease<R>, any Error>
    ] = [:]
    @ObservationIgnored
    private let tabTopology: RouterTabRestorationTopology?
    @ObservationIgnored
    private let partialConfiguration: RouterRestorationPartialConfiguration<R>?
    @ObservationIgnored
    private var initialRestorePhase: RouterInitialRestorePhase = .notStarted
    @ObservationIgnored
    private var activationGeneration: UInt64 = 0
    @ObservationIgnored
    package var saveGeneration: UInt64 = 0
    @ObservationIgnored
    package var storageEpoch: UInt64 = 0
    @ObservationIgnored
    package var statusGeneration: UInt64 = 0

    public init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail,
        saveDebounce: Duration = .milliseconds(250)
    ) {
        self.store = store
        self.codec = codec
        self.recovery = recovery
        self.tabTopology = nil
        self.partialConfiguration = nil
        self.executor = RouterByteStoreExecutor(
            load: { try storage.load() },
            save: { try storage.save($0) },
            remove: { try storage.remove() }
        )
        self.codecExecutor = RouterSnapshotCodecExecutor(codec: codec)
        self.saveDebounce = max(saveDebounce, .zero)
    }

    /// Creates a driver whose initial restore reconciles against the tab
    /// topology this application renders now.
    ///
    /// The topology belongs to this driver's lifetime. An application that
    /// changes its catalog stops this driver and creates another with the new
    /// topology rather than mutating one in place.
    public init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail,
        tabTopology: RouterTabRestorationTopology,
        saveDebounce: Duration = .milliseconds(250)
    ) {
        self.store = store
        self.codec = codec
        self.recovery = recovery
        self.tabTopology = tabTopology
        self.partialConfiguration = nil
        self.executor = RouterByteStoreExecutor(
            load: { try storage.load() },
            save: { try storage.save($0) },
            remove: { try storage.remove() }
        )
        self.codecExecutor = RouterSnapshotCodecExecutor(codec: codec)
        self.saveDebounce = max(saveDebounce, .zero)
    }

    /// Creates a driver that validates decoded routes before its initial
    /// restore and then observes the accepted canonical Store state.
    ///
    /// This opt-in path does not use snapshot recovery. Decode, migration, and
    /// validation failures remain visible to the caller and through `status`.
    public init(
        store: RouterStore<R>,
        codec: RouterSnapshotCodec<R>,
        storage: any RouterSnapshotStorage,
        validator: RouterPartialRestorationValidator<R>,
        validationTimeout: Duration? = nil,
        tabTopology: RouterTabRestorationTopology? = nil,
        saveDebounce: Duration = .milliseconds(250)
    ) {
        self.store = store
        self.codec = codec
        self.recovery = .fail
        self.tabTopology = tabTopology
        self.partialConfiguration = .init(
            validator: validator,
            validationTimeout: validationTimeout
        )
        self.executor = RouterByteStoreExecutor(
            load: { try storage.load() },
            save: { try storage.save($0) },
            remove: { try storage.remove() }
        )
        self.codecExecutor = RouterSnapshotCodecExecutor(codec: codec)
        self.saveDebounce = max(saveDebounce, .zero)
    }

    // Work around swiftlang/swift#90625 in Swift 6.3.x release builds.
    #if compiler(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        activationTask?.cancel()
        activationWaiters.values.forEach { $0.resume(throwing: CancellationError()) }
        if let activeRestoreRequestRootID {
            store.cancelRequestFamily(activeRestoreRequestRootID)
        }
        if let observationID {
            store.removeSynchronousEventObserver(observationID)
        }
        scheduledSaveTask?.cancel()
    }
}

extension RouterRestorationDriver {
    /// Starts commit observation and performs the initial restore once.
    @discardableResult
    public func activate() async throws -> RouterRestorationDriverActivation<R> {
        let claimID = UUID()
        pendingManualActivationIDs.insert(claimID)
        return try await withTaskCancellationHandler {
            do {
                let lease = try await activateIfNeeded()
                try Task.checkCancellation()
                guard pendingManualActivationIDs.remove(claimID) != nil,
                      activationGeneration == lease.generation,
                      observationID != nil else {
                    throw CancellationError()
                }
                retainsManualActivation = true
                return lease.result
            } catch {
                pendingManualActivationIDs.remove(claimID)
                stopActivationIfUnowned()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelManualActivation(claimID)
            }
        }
    }

    private func activateIfNeeded() async throws -> RouterRestorationActivationLease<R> {
        guard observationID == nil, activationTask == nil else {
            return .init(result: .alreadyActive, generation: activationGeneration)
        }

        activationGeneration &+= 1
        let generation = activationGeneration
        let statusOwner = beginStatusOperation()
        let expectedRevision = store.revision
        startObservation()

        guard initialRestorePhase == .notStarted else {
            publishStatus(.active, ownedBy: statusOwner)
            let result = RouterRestorationDriverActivation<R>.observationResumed
            lastActivation = result
            return .init(result: result, generation: generation)
        }

        initialRestorePhase = .inProgress
        lastPartialRestoration = nil
        publishStatus(.loading, ownedBy: statusOwner)
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                activationWaiters[waiterID] = continuation
                startActivationTask(
                    generation: generation,
                    statusOwner: statusOwner,
                    expectedRevision: expectedRevision
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActivationWaiter(waiterID)
            }
        }
    }

    private func startActivationTask(
        generation: UInt64,
        statusOwner: UInt64,
        expectedRevision: UInt64
    ) {
        guard activationTask == nil else { return }
        let taskID = UUID()
        activationTaskID = taskID
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.store.runtimeDependencies.didFinishRestorationWorker() }
            do {
                try await self.store.runtimeDependencies.beforeRestorationWorker()
                let result = try await self.performActivation(
                    taskID: taskID,
                    generation: generation,
                    statusOwner: statusOwner,
                    expectedRevision: expectedRevision
                )
                self.finishActivation(taskID, result: .success(result))
            } catch {
                self.finishActivation(taskID, result: .failure(error))
            }
        }
    }

    private func performActivation(
        taskID: UUID,
        generation: UInt64,
        statusOwner: UInt64,
        expectedRevision: UInt64
    ) async throws -> RouterRestorationActivationLease<R> {
        try ensureCurrentActivation(generation, taskID: taskID)
        do {
            let data = try await executor.load()
            try ensureCurrentActivation(generation, taskID: taskID)
            guard let data else {
                publishStatus(.active, ownedBy: statusOwner)
                initialRestorePhase = .completed
                let result = RouterRestorationDriverActivation<R>.noSnapshot
                lastActivation = result
                lastPartialRestoration = nil
                return .init(result: result, generation: generation)
            }
            let transitionID = store.reserveTransitionID()
            activeRestoreTransitionID = transitionID
            activeRestoreRequestRootID = transitionID
            defer {
                if activeRestoreTransitionID == transitionID {
                    activeRestoreTransitionID = nil
                }
            }
            let precondition: RouterRequestPrecondition<R> = { [weak self] _ in
                guard let self,
                      self.activationGeneration == generation,
                      self.observationID != nil else {
                    return .cancelled
                }
                return nil
            }
            let outcome: RouterRestorationOutcome<R>
            if let partialConfiguration {
                let decoded = try await codecExecutor.decode(data)
                let partial = try await store.restorePartially(
                    decoded: decoded,
                    validator: partialConfiguration.validator,
                    tabTopology: tabTopology,
                    validationTimeout: partialConfiguration.validationTimeout,
                    expectedRevision: expectedRevision,
                    transitionID: transitionID,
                    requestRootID: transitionID,
                    executionPrecondition: precondition
                )
                outcome = RouterRestorationOutcome(
                    decoding: .restored(decoded),
                    transition: partial.transition
                )
                try ensureCurrentActivation(generation, taskID: taskID)
                lastPartialRestoration = partial
            } else {
                outcome = try await store.restore(
                    from: data,
                    using: codec,
                    recovery: recovery,
                    expectedRevision: expectedRevision,
                    transitionID: transitionID,
                    requestRootID: transitionID,
                    tabTopology: tabTopology,
                    executionPrecondition: precondition
                )
            }
            if case .deferred(_, _, _, let deferral) = outcome.transition {
                activeRestoreDeferralID = deferral.id
            } else {
                clearActiveRestoreRequest(transitionID)
            }
            try ensureCurrentActivation(generation, taskID: taskID)
            publishStatus(.active, ownedBy: statusOwner)
            initialRestorePhase = .completed
            let result = RouterRestorationDriverActivation.restored(outcome)
            lastActivation = result
            if partialConfiguration != nil,
               case .unchanged = outcome.transition {
                scheduleSave()
            }
            return .init(result: result, generation: generation)
        } catch is CancellationError {
            guard activationGeneration == generation,
                  activationTaskID == taskID else {
                throw CancellationError()
            }
            initialRestorePhase = .notStarted
            lastPartialRestoration = nil
            cancelActiveRestoreRequest()
            stopObservation()
            invalidateScheduledSave()
            publishStatus(.inactive, ownedBy: statusOwner)
            throw CancellationError()
        } catch {
            guard activationGeneration == generation,
                  activationTaskID == taskID else {
                throw CancellationError()
            }
            initialRestorePhase = .notStarted
            lastPartialRestoration = nil
            cancelActiveRestoreRequest()
            stopObservation()
            invalidateScheduledSave()
            publishStatus(.failed(String(describing: error)), ownedBy: statusOwner)
            throw error
        }
    }

    /// Stops automatic observation. A later activation resumes observation
    /// without replaying the initial snapshot over newer in-memory state.
    public func stop() {
        if initialRestorePhase == .inProgress {
            initialRestorePhase = .explicitlyStopped
        }
        retainsManualActivation = false
        pendingManualActivationIDs.removeAll()
        attachmentIDs.removeAll()
        stopOwnedWork()
    }

    package func attach(_ id: UUID) async throws -> RouterRestorationDriverActivation<R> {
        attachmentIDs.insert(id)
        let lease = try await activateIfNeeded()
        try Task.checkCancellation()
        guard attachmentIDs.contains(id),
              activationGeneration == lease.generation,
              observationID != nil else {
            throw CancellationError()
        }
        return lease.result
    }

    package var attachmentCount: Int { attachmentIDs.count }
    package var activationWaiterCount: Int { activationWaiters.count }

    package func detach(_ id: UUID) {
        attachmentIDs.remove(id)
        guard attachmentIDs.isEmpty,
              pendingManualActivationIDs.isEmpty,
              !retainsManualActivation else {
            return
        }
        if initialRestorePhase == .inProgress {
            initialRestorePhase = .notStarted
        }
        stopOwnedWork()
    }

    private func stopOwnedWork() {
        let statusOwner = beginStatusOperation()
        activationGeneration &+= 1
        activationTask?.cancel()
        activationTask = nil
        activationTaskID = nil
        let waiters = activationWaiters.values
        activationWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        cancelActiveRestoreRequest()
        stopObservation()
        invalidateScheduledSave()
        publishStatus(.inactive, ownedBy: statusOwner)
    }

    package var observationStatus: RouterRestorationDriverStatus {
        observationID == nil ? .inactive : .active
    }

    package func beginStatusOperation() -> UInt64 {
        statusGeneration &+= 1
        return statusGeneration
    }

    package func publishStatus(_ value: RouterRestorationDriverStatus, ownedBy owner: UInt64) {
        guard statusGeneration == owner else { return }
        status = value
    }

    private func finishActivation(
        _ taskID: UUID,
        result: Result<RouterRestorationActivationLease<R>, any Error>
    ) {
        guard activationTaskID == taskID else { return }
        activationTask = nil
        activationTaskID = nil
        let waiters = activationWaiters.values
        activationWaiters.removeAll()
        for waiter in waiters {
            switch result {
            case .success(let lease):
                waiter.resume(returning: lease)
            case .failure(let error):
                waiter.resume(throwing: error)
            }
        }
    }

    private func cancelActivationWaiter(_ id: UUID) {
        activationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelManualActivation(_ id: UUID) {
        pendingManualActivationIDs.remove(id)
        stopActivationIfUnowned()
    }

    private func stopActivationIfUnowned() {
        guard attachmentIDs.isEmpty,
              pendingManualActivationIDs.isEmpty,
              !retainsManualActivation,
              activationTask != nil || observationID != nil else {
            return
        }
        if initialRestorePhase == .inProgress {
            initialRestorePhase = .notStarted
        }
        stopOwnedWork()
    }

    private func ensureCurrentActivation(_ activation: UInt64, taskID: UUID) throws {
        try Task.checkCancellation()
        guard activationGeneration == activation,
              activationTaskID == taskID,
              observationID != nil else {
            throw CancellationError()
        }
    }

    private func startObservation() {
        guard observationID == nil else { return }
        observationID = store.addSynchronousEventObserver { [weak self] event in
            self?.observe(event)
        }
    }

    private func observe(_ event: RouterEvent<R>) {
        switch event {
        case .committed(let transitionID, _, _, _, let context):
            finishRestoreIfNeeded(transitionID: transitionID, context: context)
            scheduleSave()
        case .unchanged(let transitionID, _, _, let context),
             .rejected(let transitionID, _, _, _, let context):
            finishRestoreIfNeeded(transitionID: transitionID, context: context)
        case .deferred(let transitionID, _, _, let deferral, let context):
            guard isActiveRestoreEvent(transitionID: transitionID, context: context) else {
                return
            }
            activeRestoreDeferralID = deferral.id
        case .started, .policyPrepared, .platformAdapted:
            break
        }
    }

    private func finishRestoreIfNeeded(
        transitionID: RouterTransitionID,
        context: RouterTransitionContext
    ) {
        guard isActiveRestoreEvent(transitionID: transitionID, context: context) else {
            return
        }
        clearActiveRestoreRequest()
    }

    private func isActiveRestoreEvent(
        transitionID: RouterTransitionID,
        context: RouterTransitionContext
    ) -> Bool {
        guard context.source == .restoration else { return false }
        if transitionID == activeRestoreTransitionID { return true }
        guard let activeRestoreDeferralID else { return false }
        return context.resumedDeferral == activeRestoreDeferralID
    }

    private func clearActiveRestoreRequest(_ matching: RouterTransitionID? = nil) {
        guard matching == nil || activeRestoreRequestRootID == matching else { return }
        activeRestoreTransitionID = nil
        activeRestoreRequestRootID = nil
        activeRestoreDeferralID = nil
    }

    private func cancelActiveRestoreRequest() {
        if let activeRestoreRequestRootID {
            store.cancelRequestFamily(activeRestoreRequestRootID)
        }
        clearActiveRestoreRequest()
    }

    private func stopObservation() {
        guard let observationID else { return }
        store.removeSynchronousEventObserver(observationID)
        self.observationID = nil
    }
}
