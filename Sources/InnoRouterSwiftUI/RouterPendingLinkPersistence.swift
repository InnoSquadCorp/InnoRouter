// MARK: - RouterPendingLinkPersistence.swift
// InnoRouterSwiftUI - opt-in persistence for authentication-gated links
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation

import InnoRouterCore
import InnoRouterDeepLink

/// Application-selected transport for one encoded pending router link.
public protocol RouterPendingLinkStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// Atomic file-backed pending-link storage at an application-owned URL.
public struct RouterFilePendingLinkStorage: RouterPendingLinkStorage, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Observable lifecycle of pending-link persistence.
public enum RouterPendingLinkPersistenceStatus: Sendable, Hashable {
    case inactive
    case loading
    case active
    case saving
    case failed(String)
}

/// Result of loading app-owned pending-link storage.
public enum RouterPendingLinkRestoration<R: Route>: Sendable, Equatable {
    case noStoredLink
    case restored(RouterPendingLinkSubmission<R>)
    case supersededByNewerInMemoryLink
}

private struct RouterPendingLinkEnvelope<R: Route & Codable>: Codable {
    let schemaVersion: Int
    let link: PendingRouterLink<R>
}

public enum RouterPendingLinkPersistenceError: Error, Sendable, Hashable {
    case unsupportedSchemaVersion(Int)
}

private actor RouterPendingLinkStorageExecutor {
    let storage: any RouterPendingLinkStorage

    init(storage: any RouterPendingLinkStorage) {
        self.storage = storage
    }

    func load() throws -> Data? { try storage.load() }
    func save(_ data: Data) throws { try storage.save(data) }
    func remove() throws { try storage.remove() }
}

private actor RouterPendingLinkCodec<R: Route & Codable> {
    func encode(_ link: PendingRouterLink<R>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            RouterPendingLinkEnvelope(schemaVersion: 1, link: link)
        )
    }

    func decode(_ data: Data) throws -> PendingRouterLink<R> {
        let envelope = try JSONDecoder().decode(
            RouterPendingLinkEnvelope<R>.self,
            from: data
        )
        guard envelope.schemaVersion == 1 else {
            throw RouterPendingLinkPersistenceError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }
        return envelope.link
    }
}

/// Explicit persistence coordinator for one ``RouterPendingLinkSlot``.
///
/// The driver does not own navigation state. Slow loads cannot overwrite a
/// newer in-memory submission, and saves converge on the latest slot generation.
@MainActor
@Observable
public final class RouterPendingLinkPersistenceDriver<R: Route & Codable> {
    public private(set) var status: RouterPendingLinkPersistenceStatus = .inactive

    @ObservationIgnored private let slot: RouterPendingLinkSlot<R>
    @ObservationIgnored private let storage: RouterPendingLinkStorageExecutor
    @ObservationIgnored private let codec = RouterPendingLinkCodec<R>()
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var cancellationOperation: UInt64?

    public init(
        slot: RouterPendingLinkSlot<R>,
        storage: any RouterPendingLinkStorage
    ) {
        self.slot = slot
        self.storage = RouterPendingLinkStorageExecutor(storage: storage)
    }

    /// Loads once without replacing a slot mutation that occurred during I/O.
    public func restore(
        replacing policy: RouterPendingLinkReplacementPolicy = .keepExisting
    ) async throws -> RouterPendingLinkRestoration<R> {
        let expectedGeneration = slot.mutationGeneration
        let operation = beginOperation(status: .loading)
        do {
            let storedData = try await storage.load()
            try validateOperation(operation)
            guard let storedData else {
                finishOperation(operation)
                return .noStoredLink
            }
            let link = try await codec.decode(storedData)
            try validateOperation(operation)
            guard slot.mutationGeneration == expectedGeneration else {
                finishOperation(operation)
                return .supersededByNewerInMemoryLink
            }
            let submission = slot.submit(link, replacing: policy)
            finishOperation(operation)
            return .restored(submission)
        } catch {
            failOperation(operation, with: error)
            throw error
        }
    }

    /// Persists the newest slot generation, retrying if it changes during I/O.
    public func save() async throws {
        let operation = beginOperation(status: .saving)
        do {
            try await persist(operation: operation)
            finishOperation(operation)
        } catch {
            failOperation(operation, with: error)
            throw error
        }
    }

    /// Submits and durably records one gated link.
    @discardableResult
    public func submit(
        _ link: PendingRouterLink<R>,
        replacing policy: RouterPendingLinkReplacementPolicy = .replaceExisting
    ) async throws -> RouterPendingLinkSubmission<R> {
        let operation = beginOperation(status: .saving)
        let result = slot.submit(link, replacing: policy)
        do {
            try await persist(operation: operation)
            finishOperation(operation)
            return result
        } catch {
            failOperation(operation, with: error)
            throw error
        }
    }

    /// Cancels the in-memory continuation and removes persisted storage.
    @discardableResult
    public func cancel() async throws -> PendingRouterLink<R>? {
        let operation = beginOperation(status: .saving)
        cancellationOperation = operation
        let cancelled = slot.cancel()
        do {
            try await persist(operation: operation)
            finishOperation(operation)
            return cancelled
        } catch {
            failOperation(operation, with: error)
            throw error
        }
    }

    /// Resumes through the canonical store and persists the resulting slot.
    ///
    /// Once the Store has produced a terminal outcome, required durability
    /// work finishes even if the caller is cancelled. A storage failure is
    /// still thrown without rolling back an already committed navigation.
    public func resume(
        on store: RouterStore<R>,
        source: RouterTransitionSource = .deepLink,
        consuming policy: RouterPendingLinkConsumptionPolicy = .onAcceptance
    ) async throws -> RouterLinkExecution<R>? {
        let operationBeforeResume = operationGeneration
        let execution = await slot.resume(
            on: store,
            source: source,
            consuming: policy
        )
        // A driver cancellation both invalidates the Store request and owns
        // durable removal. Do not let the cancelled resume supersede that
        // newer operation when it returns from the Store pipeline.
        if operationGeneration != operationBeforeResume,
           cancellationOperation == operationGeneration,
           slot.pending == nil,
           execution?.wasCancelled == true {
            return execution
        }
        // A lifecycle save that runs while policy evaluation is suspended must
        // not invalidate the durability work required by a later consumption.
        // Acquire persistence ownership only after the Store has produced the
        // execution and the slot has applied its consumption policy.
        let operation = beginOperation(status: .saving)
        do {
            try await persist(
                operation: operation,
                checksTaskCancellation: false
            )
            finishOperation(operation)
            return execution
        } catch {
            failOperation(operation, with: error)
            throw error
        }
    }

    private func beginOperation(status: RouterPendingLinkPersistenceStatus) -> UInt64 {
        operationGeneration &+= 1
        cancellationOperation = nil
        self.status = status
        return operationGeneration
    }

    private func validateOperation(
        _ operation: UInt64,
        checksTaskCancellation: Bool = true
    ) throws {
        if checksTaskCancellation {
            try Task.checkCancellation()
        }
        guard operationGeneration == operation else { throw CancellationError() }
    }

    private func finishOperation(_ operation: UInt64) {
        guard operationGeneration == operation else { return }
        status = .active
    }

    private func failOperation(_ operation: UInt64, with error: any Error) {
        guard operationGeneration == operation else { return }
        if error is CancellationError {
            status = .active
        } else {
            status = .failed(String(describing: error))
        }
    }

    private func persist(
        operation: UInt64,
        checksTaskCancellation: Bool = true
    ) async throws {
        while true {
            try validateOperation(
                operation,
                checksTaskCancellation: checksTaskCancellation
            )
            let generation = slot.mutationGeneration
            if let pending = slot.pending {
                let data = try await codec.encode(pending)
                try validateOperation(
                    operation,
                    checksTaskCancellation: checksTaskCancellation
                )
                try await storage.save(data)
            } else {
                try await storage.remove()
            }
            try validateOperation(
                operation,
                checksTaskCancellation: checksTaskCancellation
            )
            guard slot.mutationGeneration != generation else { return }
        }
    }
}

private extension RouterLinkExecution {
    var wasCancelled: Bool {
        guard case .completed(_, .rejected(_, _, _, .cancelled)) = self else {
            return false
        }
        return true
    }
}
