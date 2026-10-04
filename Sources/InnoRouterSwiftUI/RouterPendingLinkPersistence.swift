// MARK: - RouterPendingLinkPersistence.swift
// InnoRouterSwiftUI - opt-in persistence for authentication-gated links
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation

import InnoRouterCore
import InnoRouterDeepLink

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

private actor RouterPendingLinkCodecExecutor<R: Route> {
    private let codec: RouterPendingLinkCodec<R>
    init(codec: RouterPendingLinkCodec<R>) { self.codec = codec }
    func encode(_ record: RouterDurablePendingLink<R>) throws -> Data { try codec.encode(record) }
    func decode(_ data: Data, now: Date) throws -> RouterDurablePendingLink<R> { try codec.decode(data, now: now) }
}

/// Explicit persistence coordinator for one ``RouterPendingLinkSlot``.
///
/// The driver does not own navigation state. Slow loads cannot overwrite a
/// newer in-memory submission, and saves converge on the latest slot generation.
@MainActor
@Observable
public final class RouterPendingLinkPersistenceDriver<R: Route> {
    public private(set) var status: RouterPendingLinkPersistenceStatus = .inactive

    @ObservationIgnored private let durability = RouterDurabilityGate()
    @ObservationIgnored private let slot: RouterPendingLinkSlot<R>
    @ObservationIgnored private let storage: RouterByteStoreExecutor
    @ObservationIgnored private let codec: RouterPendingLinkCodecExecutor<R>
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let lifetime: Duration?
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var cancellationOperation: UInt64?

    public init(
        slot: RouterPendingLinkSlot<R>,
        storage: any RouterPendingLinkStorage,
        codec: RouterPendingLinkCodec<R>,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.slot = slot
        self.codec = RouterPendingLinkCodecExecutor(codec: codec)
        self.now = now
        self.lifetime = codec.lifetime
        slot.configureDurableLifetime(lifetime: codec.lifetime, now: now)
        self.storage = RouterByteStoreExecutor(
            load: { try storage.load() },
            save: { try storage.save($0) },
            remove: { try storage.remove() }
        )
    }

    /// Source-compatible legacy initializer. New files retain their origin;
    /// historical files without a timestamp reject unless a policy is explicit.
    public convenience init(
        slot: RouterPendingLinkSlot<R>,
        storage: any RouterPendingLinkStorage,
        legacyTimestampPolicy: RouterLegacyPendingLinkTimestampPolicy = .rejectMissingTimestamp,
        lifetime: Duration? = .seconds(24 * 60 * 60),
        now: @escaping @Sendable () -> Date = { Date() }
    ) where R: Codable {
        self.init(slot: slot, storage: storage, codec: .init(legacyTimestampPolicy: legacyTimestampPolicy, lifetime: lifetime), now: now)
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
            let record = try await codec.decode(storedData, now: now())
            try validateOperation(operation)
            guard slot.mutationGeneration == expectedGeneration else {
                finishOperation(operation)
                return .supersededByNewerInMemoryLink
            }
            try RouterPendingLinkCodec<R>.validateLifetime(record, now: now(), lifetime: lifetime)
            let submission = slot.submit(record.link, replacing: policy)
            if case .keptExisting = submission {
                // Existing live intent retains its own original lifetime.
            } else {
                slot.restoreDurableLifetime(originatedAt: record.originatedAt, lastObservedAt: record.lastObservedAt)
            }
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
        using pipeline: RouterLinkPipeline<R>? = nil,
        source: RouterTransitionSource = .deepLink,
        consuming policy: RouterPendingLinkConsumptionPolicy = .onAcceptance
    ) async throws -> RouterLinkExecution<R>? {
        if let pending = slot.pending { _ = try slot.durableLifetime?.validate(link: pending) }
        let operationBeforeResume = operationGeneration
        let execution = await slot.resume(
            on: store,
            using: pipeline,
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
            let pending = slot.pending
            // Reserve before encoding so a cancel or consume accepted after
            // this write cannot be overtaken by it.
            let ticket = durability.reserve(pending == nil ? .remove : .save)
            defer { durability.finish(ticket) }
            if let pending {
                guard let lifetime = slot.durableLifetime else { throw RouterPendingLinkLifetimeFailure(code: .missingOriginTimestamp) }
                let record = try lifetime.validate(link: pending)
                let data = try await codec.encode(record)
                try validateOperation(
                    operation,
                    checksTaskCancellation: checksTaskCancellation
                )
                // A skipped save leaves the newer state to the loop below.
                if await durability.waitForTurn(ticket) {
                    _ = try lifetime.validate(link: pending)
                    try await storage.save(data)
                }
            } else {
                _ = await durability.waitForTurn(ticket)
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
