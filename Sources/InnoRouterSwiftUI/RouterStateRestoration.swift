// MARK: - RouterStateRestoration.swift
// InnoRouterSwiftUI - opt-in snapshot transport and scene lifecycle driver
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation
import SwiftUI

import InnoRouterCore

/// Application-selected transport for one opaque router snapshot.
///
/// Storage operations are synchronous by design and are executed by
/// ``RouterRestorationDriver`` on a private actor, never on the main actor.
/// Implementations should write atomically and must not add implicit cloud
/// synchronization or analytics behavior.
public protocol RouterSnapshotStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// Atomic file-backed snapshot storage at an application-owned URL.
public struct RouterFileSnapshotStorage: RouterSnapshotStorage, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Observable lifecycle of an opt-in restoration driver.
public enum RouterRestorationDriverStatus: Sendable, Hashable {
    case inactive
    case loading
    case active
    case saving
    case failed(String)
}

/// Result of activating automatic observation and restoration.
public enum RouterRestorationDriverActivation<R: Route>: Sendable, Hashable {
    case noSnapshot
    case restored(RouterRestorationOutcome<R>)
    case observationResumed
    case alreadyActive
}

private actor RouterSnapshotStorageExecutor {
    let storage: any RouterSnapshotStorage

    init(storage: any RouterSnapshotStorage) {
        self.storage = storage
    }

    func load() throws -> Data? {
        try storage.load()
    }

    func save(_ data: Data) throws {
        try storage.save(data)
    }

    func remove() throws {
        try storage.remove()
    }
}

/// Opt-in automatic persistence for one canonical router store.
///
/// The driver observes committed transitions, coalesces writes, and restores
/// through the normal policy pipeline. It never becomes another state owner;
/// storage contains only snapshots produced by the supplied codec.
@MainActor
@Observable
public final class RouterRestorationDriver<R: Route & Codable> {
    public private(set) var status: RouterRestorationDriverStatus = .inactive
    public private(set) var lastActivation: RouterRestorationDriverActivation<R>?

    @ObservationIgnored
    private let store: RouterStore<R>
    @ObservationIgnored
    private let codec: RouterSnapshotCodec<R>
    @ObservationIgnored
    private let recovery: RouterSnapshotRecoveryPolicy<R>
    @ObservationIgnored
    private let executor: RouterSnapshotStorageExecutor
    @ObservationIgnored
    private let codecExecutor: RouterSnapshotCodecExecutor<R>
    @ObservationIgnored
    private let saveDebounce: Duration
    @ObservationIgnored
    private var observationID: UUID?
    @ObservationIgnored
    private var scheduledSaveTask: Task<Void, Never>?
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
    private var didAttemptRestore = false
    @ObservationIgnored
    private var activationGeneration: UInt64 = 0
    @ObservationIgnored
    private var saveGeneration: UInt64 = 0
    @ObservationIgnored
    private var storageEpoch: UInt64 = 0

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
        self.executor = RouterSnapshotStorageExecutor(storage: storage)
        self.codecExecutor = RouterSnapshotCodecExecutor(codec: codec)
        self.saveDebounce = max(saveDebounce, .zero)
    }

    // Work around swiftlang/swift#90625 in Swift 6.3.x release builds.
    #if compiler(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        if let activeRestoreRequestRootID {
            store.cancelRequestFamily(activeRestoreRequestRootID)
        }
        if let observationID {
            store.removeSynchronousEventObserver(observationID)
        }
        scheduledSaveTask?.cancel()
    }

    /// Starts commit observation and performs the initial restore once.
    @discardableResult
    public func activate() async throws -> RouterRestorationDriverActivation<R> {
        retainsManualActivation = true
        do {
            return try await activateIfNeeded()
        } catch {
            retainsManualActivation = false
            throw error
        }
    }

    private func activateIfNeeded() async throws -> RouterRestorationDriverActivation<R> {
        guard observationID == nil else {
            return .alreadyActive
        }
        activationGeneration &+= 1
        let activation = activationGeneration
        let expectedRevision = store.revision
        startObservation()

        guard !didAttemptRestore else {
            status = .active
            let result = RouterRestorationDriverActivation<R>.observationResumed
            lastActivation = result
            return result
        }

        didAttemptRestore = true
        status = .loading
        do {
            let data = try await executor.load()
            try ensureCurrentActivation(activation)
            guard let data else {
                status = .active
                let result = RouterRestorationDriverActivation<R>.noSnapshot
                lastActivation = result
                return result
            }
            let transitionID = store.reserveTransitionID()
            activeRestoreTransitionID = transitionID
            activeRestoreRequestRootID = transitionID
            defer {
                if activeRestoreTransitionID == transitionID {
                    activeRestoreTransitionID = nil
                }
            }
            let outcome = try await store.restore(
                from: data,
                using: codec,
                recovery: recovery,
                expectedRevision: expectedRevision,
                transitionID: transitionID,
                requestRootID: transitionID,
                executionPrecondition: { [weak self] _ in
                    guard let self,
                          self.activationGeneration == activation,
                          self.observationID != nil else {
                        return .cancelled
                    }
                    return nil
                }
            )
            if case .deferred(_, _, _, let deferral) = outcome.transition {
                activeRestoreDeferralID = deferral.id
            } else {
                clearActiveRestoreRequest(transitionID)
            }
            try ensureCurrentActivation(activation)
            status = .active
            let result = RouterRestorationDriverActivation.restored(outcome)
            lastActivation = result
            return result
        } catch is CancellationError {
            guard activationGeneration == activation else {
                throw CancellationError()
            }
            didAttemptRestore = false
            cancelActiveRestoreRequest()
            stopObservation()
            invalidateScheduledSave()
            status = .inactive
            throw CancellationError()
        } catch {
            guard activationGeneration == activation else {
                throw CancellationError()
            }
            didAttemptRestore = false
            cancelActiveRestoreRequest()
            stopObservation()
            invalidateScheduledSave()
            status = .failed(String(describing: error))
            throw error
        }
    }

    /// Encodes and atomically writes the store's latest committed state now.
    public func save() async throws {
        invalidateScheduledSave()
        let generation = saveGeneration
        let epoch = storageEpoch
        try await saveSnapshot(
            generation: generation,
            storageEpoch: epoch,
            discardIfSuperseded: false
        )
    }

    /// Removes the persisted snapshot without changing router state.
    public func removeSnapshot() async throws {
        invalidateScheduledSave()
        storageEpoch &+= 1
        do {
            try await executor.remove()
            status = observationID == nil ? .inactive : .active
        } catch {
            status = .failed(String(describing: error))
            throw error
        }
    }

    /// Stops automatic observation. A later activation resumes observation
    /// without replaying the initial snapshot over newer in-memory state.
    public func stop() {
        retainsManualActivation = false
        attachmentIDs.removeAll()
        stopOwnedWork()
    }

    package func attach(_ id: UUID) async throws -> RouterRestorationDriverActivation<R> {
        attachmentIDs.insert(id)
        return try await activateIfNeeded()
    }

    package func detach(_ id: UUID) {
        attachmentIDs.remove(id)
        guard attachmentIDs.isEmpty, !retainsManualActivation else { return }
        stopOwnedWork()
    }

    private func stopOwnedWork() {
        activationGeneration &+= 1
        cancelActiveRestoreRequest()
        stopObservation()
        invalidateScheduledSave()
        status = .inactive
    }

    private func ensureCurrentActivation(_ activation: UInt64) throws {
        try Task.checkCancellation()
        guard activationGeneration == activation,
              observationID != nil else {
            throw CancellationError()
        }
    }

    private func startObservation() {
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

    private func scheduleSave() {
        invalidateScheduledSave()
        let generation = saveGeneration
        let epoch = storageEpoch
        let delay = saveDebounce
        let sleep = store.runtimeDependencies.sleep
        scheduledSaveTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
                guard !Task.isCancelled,
                      let self,
                      self.saveGeneration == generation else { return }
                try await self.saveSnapshot(
                    generation: generation,
                    storageEpoch: epoch,
                    discardIfSuperseded: true
                )
                guard self.saveGeneration == generation else { return }
                self.scheduledSaveTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.saveGeneration == generation else { return }
                self.status = .failed(String(describing: error))
                self.scheduledSaveTask = nil
            }
        }
    }

    private func invalidateScheduledSave() {
        saveGeneration &+= 1
        scheduledSaveTask?.cancel()
        scheduledSaveTask = nil
    }

    private func saveSnapshot(
        generation: UInt64,
        storageEpoch expectedStorageEpoch: UInt64,
        discardIfSuperseded: Bool
    ) async throws {
        let data: Data
        do {
            let state = store.state
            data = try await codecExecutor.encode(state)
        } catch {
            if storageEpoch == expectedStorageEpoch,
               saveGeneration == generation {
                status = .failed(String(describing: error))
            }
            if storageEpoch != expectedStorageEpoch { return }
            if discardIfSuperseded, saveGeneration != generation { return }
            throw error
        }

        guard storageEpoch == expectedStorageEpoch else { return }
        if discardIfSuperseded, saveGeneration != generation { return }
        if saveGeneration == generation {
            status = .saving
        }
        do {
            try await executor.save(data)
            if storageEpoch == expectedStorageEpoch,
               saveGeneration == generation {
                status = observationID == nil ? .inactive : .active
            }
        } catch {
            if storageEpoch == expectedStorageEpoch,
               saveGeneration == generation {
                status = .failed(String(describing: error))
            }
            if storageEpoch != expectedStorageEpoch { return }
            if discardIfSuperseded, saveGeneration != generation { return }
            throw error
        }
    }
}

public extension View {
    /// Activates an app-owned restoration driver while this root view is live.
    ///
    /// The modifier saves immediately when the scene leaves the active phase.
    /// Restore and save failures remain visible through the driver's `status`.
    @MainActor
    func routerStateRestoration<R: Route & Codable>(
        _ driver: RouterRestorationDriver<R>
    ) -> some View {
        modifier(RouterStateRestorationModifier(driver: driver))
    }
}

@MainActor
private struct RouterStateRestorationModifier<R: Route & Codable>: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var attachmentID = UUID()
    @State private var attachedDriver: RouterRestorationDriver<R>?
    let driver: RouterRestorationDriver<R>

    func body(content: Content) -> some View {
        content
            .task(id: ObjectIdentifier(driver)) {
                if let attachedDriver, attachedDriver !== driver {
                    attachedDriver.detach(attachmentID)
                }
                attachedDriver = driver
                _ = try? await driver.attach(attachmentID)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                Task { @MainActor in
                    try? await driver.save()
                }
            }
            .onDisappear {
                driver.detach(attachmentID)
                if attachedDriver === driver {
                    attachedDriver = nil
                }
            }
    }
}
