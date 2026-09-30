// MARK: - RouterSnapshot.swift
// InnoRouterCore - versioned whole-router state persistence
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// A versioned, opaque container for one complete router-state payload.
///
/// Keeping the schema version outside the typed payload lets applications
/// migrate older JSON before decoding it as the current route/state shape.
public struct RouterSnapshotEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var payload: Data

    public init(schemaVersion: Int, payload: Data) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }
}

/// Application-selected byte limits for one encoded router snapshot.
///
/// Limits are opt-in so existing snapshot callers preserve their 6.0 behavior.
/// Use a matching limit on ``RouterFileSnapshotStorage`` to reject an oversized
/// file before allocating its complete contents.
public struct RouterSnapshotLimits: Hashable, Sendable {
    public let maximumEncodedByteCount: Int
    public let maximumPayloadByteCount: Int

    public init(
        maximumEncodedByteCount: Int,
        maximumPayloadByteCount: Int
    ) throws {
        guard maximumEncodedByteCount > 0 else {
            throw RouterSnapshotError.invalidByteLimit(
                name: "maximumEncodedByteCount",
                value: maximumEncodedByteCount
            )
        }
        guard maximumPayloadByteCount > 0 else {
            throw RouterSnapshotError.invalidByteLimit(
                name: "maximumPayloadByteCount",
                value: maximumPayloadByteCount
            )
        }
        self.maximumEncodedByteCount = maximumEncodedByteCount
        self.maximumPayloadByteCount = maximumPayloadByteCount
    }
}

/// One explicit, adjacent router-snapshot schema migration.
///
/// The transform receives only the encoded ``RouterState`` payload. It must
/// return payload data accepted by the next schema version.
public struct RouterSnapshotMigration: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    private let transformPayload: @Sendable (Data) throws -> Data

    public init(
        from fromVersion: Int,
        to toVersion: Int,
        transform: @escaping @Sendable (Data) throws -> Data
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.transformPayload = transform
    }

    fileprivate func transform(_ payload: Data) throws -> Data {
        try transformPayload(payload)
    }
}

public extension RouterSnapshotMigration {
    /// Builds an adjacent migration from typed, Codable payload models.
    ///
    /// `OldPayload` normally mirrors the complete legacy `RouterState` JSON
    /// shape. The transform returns the next version's complete payload, which
    /// makes schema changes compiler-checked instead of byte-string rewrites.
    static func codable<OldPayload: Decodable & Sendable, NewPayload: Encodable & Sendable>(
        from fromVersion: Int,
        to toVersion: Int,
        decoding _: OldPayload.Type,
        transform: @escaping @Sendable (OldPayload) throws -> NewPayload
    ) -> Self {
        Self(from: fromVersion, to: toVersion) { payload in
            let old = try JSONDecoder().decode(OldPayload.self, from: payload)
            let next = try transform(old)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(next)
        }
    }
}

/// Typed persistence failures surfaced before a snapshot reaches a store.
public enum RouterSnapshotError: Error, Hashable, Sendable {
    case invalidByteLimit(name: String, value: Int)
    case encodedDataTooLarge(actualByteCount: Int, maximumByteCount: Int)
    case payloadTooLarge(actualByteCount: Int, maximumByteCount: Int)
    case invalidCurrentVersion(Int)
    case invalidSnapshotVersion(Int)
    case invalidMigration(from: Int, to: Int)
    case duplicateMigration(Int)
    case encodePayload(String)
    case encodeEnvelope(String)
    case decodeEnvelope(String)
    case futureVersion(snapshot: Int, current: Int)
    case missingMigration(from: Int, current: Int)
    case migrationFailed(from: Int, to: Int, message: String)
    case decodePayload(version: Int, message: String)
    case invalidState(RouterStateValidationError)
}

/// Explicit fallback behavior for an unreadable or unmigratable snapshot.
public enum RouterSnapshotRecoveryPolicy<R: Route>: Sendable {
    /// Preserve the decode failure and require the caller to handle it.
    case fail
    /// Produce an application-owned valid fallback state with the typed reason.
    case use(@Sendable (RouterSnapshotError) -> RouterState<R>)
}

/// Distinguishes a decoded snapshot from an explicitly recovered fallback.
public enum RouterSnapshotDecodingResult<R: Route>: Hashable, Sendable {
    case restored(RouterState<R>)
    case recovered(state: RouterState<R>, reason: RouterSnapshotError)

    public var state: RouterState<R> {
        switch self {
        case .restored(let state), .recovered(let state, _): state
        }
    }
}

/// Deterministic encoder, migration runner, and validator for complete router
/// snapshots.
public struct RouterSnapshotCodec<R: Route & Codable>: Sendable {
    public let currentVersion: Int
    private let migrations: [Int: RouterSnapshotMigration]
    private let limits: RouterSnapshotLimits?

    public init(
        currentVersion: Int,
        migrations: [RouterSnapshotMigration] = []
    ) throws {
        try self.init(currentVersion: currentVersion, migrations: migrations, limits: nil)
    }

    /// Creates a codec that rejects encoded envelopes and route payloads over
    /// application-selected byte limits.
    public init(
        currentVersion: Int,
        migrations: [RouterSnapshotMigration] = [],
        limits: RouterSnapshotLimits
    ) throws {
        try self.init(currentVersion: currentVersion, migrations: migrations, limits: .some(limits))
    }

    private init(
        currentVersion: Int,
        migrations: [RouterSnapshotMigration],
        limits: RouterSnapshotLimits?
    ) throws {
        guard currentVersion > 0 else {
            throw RouterSnapshotError.invalidCurrentVersion(currentVersion)
        }

        var indexed: [Int: RouterSnapshotMigration] = [:]
        for migration in migrations {
            guard migration.fromVersion > 0,
                  migration.fromVersion < currentVersion,
                  migration.toVersion == migration.fromVersion + 1 else {
                throw RouterSnapshotError.invalidMigration(
                    from: migration.fromVersion,
                    to: migration.toVersion
                )
            }
            guard indexed[migration.fromVersion] == nil else {
                throw RouterSnapshotError.duplicateMigration(migration.fromVersion)
            }
            indexed[migration.fromVersion] = migration
        }

        self.currentVersion = currentVersion
        self.migrations = indexed
        self.limits = limits
    }

    /// Encodes the current state with stable JSON key ordering.
    public func encode(_ state: RouterState<R>) throws -> Data {
        do {
            try state.validate()
        } catch let error as RouterStateValidationError {
            throw RouterSnapshotError.invalidState(error)
        }

        let payload: Data
        do {
            payload = try Self.encoder().encode(state)
        } catch {
            throw RouterSnapshotError.encodePayload(String(describing: error))
        }
        try validatePayloadSize(payload)

        do {
            let encoded = try Self.encoder().encode(
                RouterSnapshotEnvelope(
                    schemaVersion: currentVersion,
                    payload: payload
                )
            )
            try validateEncodedSize(encoded)
            return encoded
        } catch let error as RouterSnapshotError {
            throw error
        } catch {
            throw RouterSnapshotError.encodeEnvelope(String(describing: error))
        }
    }

    /// Migrates and decodes a snapshot, then validates the resulting tree.
    public func decode(_ data: Data) throws -> RouterState<R> {
        try validateEncodedSize(data)
        var envelope: RouterSnapshotEnvelope
        do {
            envelope = try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: data)
        } catch {
            throw RouterSnapshotError.decodeEnvelope(String(describing: error))
        }

        guard envelope.schemaVersion > 0 else {
            throw RouterSnapshotError.invalidSnapshotVersion(envelope.schemaVersion)
        }
        guard envelope.schemaVersion <= currentVersion else {
            throw RouterSnapshotError.futureVersion(
                snapshot: envelope.schemaVersion,
                current: currentVersion
            )
        }
        try validatePayloadSize(envelope.payload)

        while envelope.schemaVersion < currentVersion {
            guard let migration = migrations[envelope.schemaVersion] else {
                throw RouterSnapshotError.missingMigration(
                    from: envelope.schemaVersion,
                    current: currentVersion
                )
            }
            do {
                envelope.payload = try migration.transform(envelope.payload)
            } catch {
                throw RouterSnapshotError.migrationFailed(
                    from: migration.fromVersion,
                    to: migration.toVersion,
                    message: String(describing: error)
                )
            }
            // Application migration failures keep the 6.0 error contract
            // above. A limit failure originates in the codec itself, so it
            // remains a distinct typed error for callers that opt into limits.
            try validatePayloadSize(envelope.payload)
            envelope.schemaVersion = migration.toVersion
        }

        let state: RouterState<R>
        do {
            state = try JSONDecoder().decode(RouterState<R>.self, from: envelope.payload)
        } catch let error as RouterStateValidationError {
            throw RouterSnapshotError.invalidState(error)
        } catch {
            throw RouterSnapshotError.decodePayload(
                version: envelope.schemaVersion,
                message: String(describing: error)
            )
        }

        // `RouterState.init(from:)` validates before returning. Keep this
        // explicit call as a defense against a future decoding implementation
        // that constructs the value through a different path.
        do {
            try state.validate()
        } catch let error as RouterStateValidationError {
            throw RouterSnapshotError.invalidState(error)
        }
        return state
    }

    /// Decodes using an explicit failure policy. Recovery is never implicit:
    /// callers receive whether the returned state came from the snapshot or
    /// their fallback closure.
    public func decode(
        _ data: Data,
        recovery: RouterSnapshotRecoveryPolicy<R>
    ) throws -> RouterSnapshotDecodingResult<R> {
        do {
            return .restored(try decode(data))
        } catch let error as RouterSnapshotError {
            switch recovery {
            case .fail:
                throw error
            case .use(let fallback):
                let state = fallback(error)
                do {
                    try state.validate()
                } catch let validationError as RouterStateValidationError {
                    throw RouterSnapshotError.invalidState(validationError)
                }
                return .recovered(state: state, reason: error)
            }
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func validateEncodedSize(_ data: Data) throws {
        guard let limit = limits?.maximumEncodedByteCount,
              data.count > limit else { return }
        throw RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: data.count,
            maximumByteCount: limit
        )
    }

    private func validatePayloadSize(_ data: Data) throws {
        guard let limit = limits?.maximumPayloadByteCount,
              data.count > limit else { return }
        throw RouterSnapshotError.payloadTooLarge(
            actualByteCount: data.count,
            maximumByteCount: limit
        )
    }
}
