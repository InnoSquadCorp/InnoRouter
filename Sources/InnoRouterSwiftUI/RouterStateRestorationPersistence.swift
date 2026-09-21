// MARK: - RouterStateRestorationPersistence.swift
// InnoRouterSwiftUI - durable save/remove operations for restoration drivers
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

@MainActor
extension RouterRestorationDriver {
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

    /// Flushes a mounted root when its scene leaves the active phase.
    ///
    /// Initial restore failures and unresolved candidates must not replace the
    /// app-owned snapshot with the Store's pre-restore value. A later app
    /// commit is independent evidence that the current Store state is new and
    /// may be persisted even when the original restore failed.
    package func saveForSceneLifecycle(attachmentID: UUID) async {
        guard canSaveForSceneLifecycle(attachmentID: attachmentID) else { return }
        invalidateScheduledSave()
        let generation = saveGeneration
        let epoch = storageEpoch
        try? await saveSnapshot(
            generation: generation,
            storageEpoch: epoch,
            discardIfSuperseded: true
        )
    }

    /// Removes the persisted snapshot without changing router state.
    public func removeSnapshot() async throws {
        invalidateScheduledSave()
        storageEpoch &+= 1
        let statusOwner = beginStatusOperation()
        // Reserving here invalidates every save this driver accepted earlier,
        // so a save already past its own staleness checks cannot write the
        // snapshot back after this removal.
        let ticket = durability.reserve(.remove)
        defer { durability.finish(ticket) }
        _ = await durability.waitForTurn(ticket)
        do {
            try await executor.remove()
            publishStatus(observationStatus, ownedBy: statusOwner)
        } catch {
            // Durable I/O still finishes and reports its error to its caller.
            // A newer activation/save/remove/stop owns the visible status.
            publishStatus(.failed(String(describing: error)), ownedBy: statusOwner)
            throw error
        }
    }

    package func scheduleSave() {
        invalidateScheduledSave()
        let generation = saveGeneration
        let epoch = storageEpoch
        let statusBeforeDelay = statusGeneration
        let delay = saveDebounce
        let sleep = store.runtimeDependencies.sleep
        scheduledSaveTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.saveGeneration == generation else { return }
                self.publishStatus(.failed(String(describing: error)), ownedBy: statusBeforeDelay)
                self.scheduledSaveTask = nil
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.saveGeneration == generation else { return }
            // saveSnapshot owns error publication; the background caller must
            // not publish it a second time after a newer operation starts.
            try? await self.saveSnapshot(
                generation: generation,
                storageEpoch: epoch,
                discardIfSuperseded: true
            )
            guard self.saveGeneration == generation else { return }
            self.scheduledSaveTask = nil
        }
    }

    package func invalidateScheduledSave() {
        saveGeneration &+= 1
        scheduledSaveTask?.cancel()
        scheduledSaveTask = nil
    }

    private func saveSnapshot(
        generation: UInt64,
        storageEpoch expectedStorageEpoch: UInt64,
        discardIfSuperseded: Bool
    ) async throws {
        let statusOwner = beginStatusOperation()
        // Reserve before the first suspension so this save keeps the position
        // it was accepted in, whatever priority the encode and the storage
        // call end up running at.
        let ticket = durability.reserve(.save)
        defer { durability.finish(ticket) }
        do {
            let state = store.state
            let data = try await codecExecutor.encode(state)
            guard storageEpoch == expectedStorageEpoch,
                  !discardIfSuperseded || saveGeneration == generation else {
                publishStatus(observationStatus, ownedBy: statusOwner)
                return
            }
            publishStatus(.saving, ownedBy: statusOwner)
            // A later removal owns status and forbids resurrecting its bytes.
            guard await durability.waitForTurn(ticket) else { return }
            guard storageEpoch == expectedStorageEpoch,
                  !discardIfSuperseded || saveGeneration == generation else {
                publishStatus(observationStatus, ownedBy: statusOwner)
                return
            }
            try await executor.save(data)
            publishStatus(observationStatus, ownedBy: statusOwner)
        } catch {
            guard storageEpoch == expectedStorageEpoch,
                  !discardIfSuperseded || saveGeneration == generation else {
                publishStatus(observationStatus, ownedBy: statusOwner)
                return
            }
            publishStatus(.failed(String(describing: error)), ownedBy: statusOwner)
            throw error
        }
    }
}
