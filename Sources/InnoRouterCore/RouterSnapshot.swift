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

/// Finite limits for the legacy recursive JSON snapshot format.
///
/// The default values are provisional and remain subject to application and
/// release calibration. JSON depth counts objects/arrays, including the root;
/// tokens count scalars and every structural punctuation byte. The payload cap
/// leaves room for base64 expansion inside the encoded envelope. Use a matching
/// file-storage limit to reject an oversized file before allocating its contents.
public struct RouterSnapshotLimits: Hashable, Sendable {
    public let maximumEncodedByteCount: Int
    public let maximumPayloadByteCount: Int
    public let maximumJSONDepth: Int
    public let maximumJSONTokens: Int
    public let maximumJSONWorkUnits: Int?
    public let maximumJSONKeyDecodes: Int?

    /// Uncalibrated starting values, not a measured app-compatibility guarantee.
    public static let provisional = try! Self(
        maximumEncodedByteCount: 4 * 1_024 * 1_024,
        maximumPayloadByteCount: 2 * 1_024 * 1_024
    )

    public init(
        maximumEncodedByteCount: Int,
        maximumPayloadByteCount: Int,
        maximumJSONDepth: Int = 128,
        maximumJSONTokens: Int = 262_144,
        maximumJSONWorkUnits: Int? = nil,
        maximumJSONKeyDecodes: Int? = nil
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
        for (name, value) in [
            ("maximumJSONDepth", maximumJSONDepth),
            ("maximumJSONTokens", maximumJSONTokens),
        ] where value <= 0 {
            throw RouterSnapshotError.preflight(.init(
                code: .invalidLimit, details: .init(field: name, value: value)
            ))
        }
        for (name, value) in [("maximumJSONWorkUnits", maximumJSONWorkUnits), ("maximumJSONKeyDecodes", maximumJSONKeyDecodes)] {
            if let value, value < 0 {
                throw RouterSnapshotError.preflight(.init(code: .invalidLimit, details: .init(field: name, value: value)))
            }
        }
        self.maximumEncodedByteCount = maximumEncodedByteCount
        self.maximumPayloadByteCount = maximumPayloadByteCount
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumJSONTokens = maximumJSONTokens
        self.maximumJSONWorkUnits = maximumJSONWorkUnits
        self.maximumJSONKeyDecodes = maximumJSONKeyDecodes
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
    case preflight(RouterSnapshotPreflightError)
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

extension RouterSnapshotRecoveryPolicy {
    /// Applies this policy to a snapshot that could not be read.
    ///
    /// Codec decoding and storage that rejects a snapshot before the codec
    /// reads it, such as a file over its byte limit, share this step, so the
    /// same typed failure reaches the same validated fallback either way.
    package func recover(from error: RouterSnapshotError) throws -> RouterSnapshotDecodingResult<R> {
        switch self {
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
    package let migrations: [Int: RouterSnapshotMigration]
    package let limits: RouterSnapshotLimits?
    package var resourceLimits: RouterGraphSnapshotLimits?

    /// Creates a codec with finite provisional byte and JSON-complexity limits.
    ///
    /// Pass larger finite limits after measuring the application's snapshots.
    /// Explicit `nil` opts out of the library's byte limits and JSON preflight;
    /// that configuration is excluded from the bounded-decoding guarantee.
    public init(
        currentVersion: Int,
        migrations: [RouterSnapshotMigration] = [],
        limits: RouterSnapshotLimits? = .provisional
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
        self.resourceLimits = try limits.map {
            try RouterGraphSnapshotLimits(maximumEncodedBytes: $0.maximumEncodedByteCount,
                                          maximumPayloadBytes: $0.maximumPayloadByteCount,
                                          maximumJSONTokens: $0.maximumJSONTokens)
        }
    }

    /// Encodes the current state with stable JSON key ordering.
    public func encode(_ state: RouterState<R>) throws -> Data {
        try validateResources(state, stage: "encodingState")
        var work = makeJSONWorkBudget()
        try chargeJSON(1, stage: "encodingState", work: &work)
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
        try validateJSON(payload, isEnvelope: false, version: currentVersion, work: &work)
        try validateRoutePayloads(payload, version: currentVersion, work: &work)

        do {
            try chargeJSON(1, stage: "encodingEnvelope", work: &work)
            let encoded = try Self.encoder().encode(
                RouterSnapshotEnvelope(
                    schemaVersion: currentVersion,
                    payload: payload
                )
            )
            try validateEncodedSize(encoded)
            try validateJSON(encoded, isEnvelope: true, work: &work)
            return encoded
        } catch let error as RouterSnapshotError {
            throw error
        } catch {
            throw RouterSnapshotError.encodeEnvelope(String(describing: error))
        }
    }

    /// Migrates and decodes a snapshot, then validates the resulting tree.
    public func decode(_ data: Data) throws -> RouterState<R> {
        var work = makeJSONWorkBudget()
        return try decode(data, work: &work)
    }

    private func decode(_ data: Data, work: inout RouterJSONWorkBudget?) throws -> RouterState<R> {
        try validateEncodedSize(data)
        try validateJSON(data, isEnvelope: true, work: &work)
        try chargeJSON(data.count, stage: "envelope", work: &work)
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
        try validateJSON(envelope.payload, isEnvelope: false, version: envelope.schemaVersion, work: &work)

        while envelope.schemaVersion < currentVersion {
            guard let migration = migrations[envelope.schemaVersion] else {
                throw RouterSnapshotError.missingMigration(
                    from: envelope.schemaVersion,
                    current: currentVersion
                )
            }
            try chargeJSON(envelope.payload.count, stage: "migration", work: &work)
            do {
                envelope.payload = try migration.transform(envelope.payload)
            } catch {
                throw RouterSnapshotError.migrationFailed(
                    from: migration.fromVersion,
                    to: migration.toVersion,
                    message: String(describing: error)
                )
            }
            // Application failures keep their existing contract. Codec bounds
            // remain distinct and run after every hop, before another migration
            // (including its typed JSONDecoder) can consume the output.
            try validatePayloadSize(envelope.payload)
            try validateJSON(envelope.payload, isEnvelope: false, version: migration.toVersion, work: &work)
            envelope.schemaVersion = migration.toVersion
        }

        try validateRoutePayloads(envelope.payload, version: envelope.schemaVersion, work: &work)
        try chargeJSON(envelope.payload.count, stage: "payload", work: &work)
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
            return try recovery.recover(from: error)
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

    private func validateRoutePayloads(_ data: Data, version: Int, work: inout RouterJSONWorkBudget?) throws {
        if let resourceLimits {
            try chargeJSON(data.count, stage: "structuralPayload", work: &work)
            do {
                guard let admittedWork = work else {
                    throw RouterSnapshotError.preflight(.init(code: .invalidLimit, details: .init(
                        stage: "payload", field: "missingWorkBudget"
                    )))
                }
                let admission = try RouterLegacyRouteAdmission(
                    validatedJSON: data, limits: resourceLimits, work: admittedWork
                )
                let decoder = JSONDecoder()
                decoder.userInfo[RouterLegacyRouteAdmission.key] = admission
                let shape = try decoder.decode(RouterState<RouterLegacyRouteShape>.self, from: data)
                work = admission.work
                try validateResources(shape, stage: "payload")
            } catch let error as RouterStateValidationError { throw RouterSnapshotError.invalidState(error) }
            catch let error as RouterSnapshotError { throw error }
            catch RouterJSONPreflightError.limitExceeded(let field, let actual, let maximum) {
                throw RouterSnapshotError.preflight(.init(code: .limitExceeded, details: .init(
                    stage: "payload", field: field, actual: actual, maximum: maximum
                )))
            } catch { throw RouterSnapshotError.decodePayload(version: version, message: "Invalid state structure") }
        }
    }

    package mutating func setResourceLimits(_ configured: RouterGraphSnapshotLimits) {
        resourceLimits = configured
    }

    private func validateResources<StateRoute: Route>(_ state: RouterState<StateRoute>, stage: String) throws {
        guard let resourceLimits else { return }
        do { try RouterResourceBudget(snapshot: resourceLimits).validate(state) }
        catch let failure {
            throw RouterSnapshotError.preflight(.init(code: .limitExceeded, details: .init(
                stage: stage, field: failure.resource, actual: failure.actual, maximum: failure.maximum
            )))
        }
    }

    private func jsonWorkLimits(_ limits: RouterSnapshotLimits) -> RouterJSONWorkLimits {
        let derived = RouterJSONWorkLimits.derived(maximumBytes: limits.maximumEncodedByteCount, maximumTokens: limits.maximumJSONTokens)
        return .init(maximumWorkUnits: limits.maximumJSONWorkUnits ?? derived.maximumWorkUnits,
                     maximumKeyDecodes: limits.maximumJSONKeyDecodes ?? derived.maximumKeyDecodes)
    }

    private func makeJSONWorkBudget() -> RouterJSONWorkBudget? {
        limits.map { RouterJSONWorkBudget(limits: jsonWorkLimits($0)) }
    }

    private func chargeJSON(_ count: Int, stage: String, work: inout RouterJSONWorkBudget?) throws {
        do { try work?.charge(count) }
        catch RouterJSONPreflightError.limitExceeded(let field, let actual, let maximum) {
            throw RouterSnapshotError.preflight(.init(code: .limitExceeded, details: .init(
                stage: stage, field: field, actual: actual, maximum: maximum
            )))
        }
    }

    package func decodeForGraphMigration(_ data: Data, work: inout RouterJSONWorkBudget) throws -> RouterState<R> {
        let prior = work.result
        let local = limits.map(jsonWorkLimits) ?? work.limits
        let admitted = RouterJSONWorkLimits(
            maximumWorkUnits: min(local.maximumWorkUnits, work.limits.maximumWorkUnits - prior.workUnits),
            maximumKeyDecodes: min(local.maximumKeyDecodes, work.limits.maximumKeyDecodes - prior.keyDecodes)
        )
        var nested: RouterJSONWorkBudget? = .init(limits: admitted)
        let state = try decode(data, work: &nested)
        if let used = nested?.result {
            // Each local count was admitted against the remaining outer count.
            work = try RouterJSONWorkBudget(limits: work.limits, consumed: .init(
                workUnits: prior.workUnits + used.workUnits, keyDecodes: prior.keyDecodes + used.keyDecodes
            ))
        }
        return state
    }

    /// A graph migration never inherits an unbounded legacy parser. Preserve
    /// stricter app limits while bounding every original migration output.
    package func boundedForGraphMigration(_ graph: RouterGraphSnapshotLimits, maximumLegacyJSONDepth: Int? = nil) throws -> Self {
        let baseline = limits ?? .provisional
        let bounded = try RouterSnapshotLimits(
            maximumEncodedByteCount: min(baseline.maximumEncodedByteCount, graph.maximumEncodedBytes),
            maximumPayloadByteCount: min(baseline.maximumPayloadByteCount, graph.maximumPayloadBytes),
            maximumJSONDepth: min(baseline.maximumJSONDepth, maximumLegacyJSONDepth ?? max(RouterSnapshotLimits.provisional.maximumJSONDepth, graph.maximumJSONDepth)),
            maximumJSONTokens: min(baseline.maximumJSONTokens, graph.maximumJSONTokens),
            maximumJSONWorkUnits: baseline.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: baseline.maximumJSONKeyDecodes
        )
        var adapted = try Self(currentVersion: currentVersion, migrations: Array(migrations.values), limits: bounded)
        adapted.setResourceLimits(try resourceLimits?.intersecting(graph) ?? graph)
        return adapted
    }

    private func validateJSON(_ data: Data, isEnvelope: Bool, version: Int? = nil) throws {
        var work = makeJSONWorkBudget()
        try validateJSON(data, isEnvelope: isEnvelope, version: version, work: &work)
    }

    private func validateJSON(
        _ data: Data, isEnvelope: Bool, version: Int? = nil, work: inout RouterJSONWorkBudget?
    ) throws {
        guard let limits else { return }
        do {
            let selected = work?.limits ?? jsonWorkLimits(limits)
            let used = try RouterJSONPreflight.validate(
                data,
                maximumBytes: isEnvelope ? limits.maximumEncodedByteCount : limits.maximumPayloadByteCount,
                maximumDepth: limits.maximumJSONDepth,
                maximumTokens: limits.maximumJSONTokens,
                byteName: isEnvelope ? "encodedBytes" : "payloadBytes",
                workLimits: selected, consumedWork: work?.result
            )
            work = try RouterJSONWorkBudget(limits: selected, consumed: used)
        } catch let error as RouterJSONPreflightError {
            let stage = isEnvelope ? "envelope" : "payload"
            switch error {
            case .malformedJSON:
                // Keep the legacy error boundary without retaining input text.
                if isEnvelope { throw RouterSnapshotError.decodeEnvelope("Malformed JSON") }
                throw RouterSnapshotError.decodePayload(version: version ?? currentVersion, message: "Malformed JSON")
            case .duplicateJSONKey:
                throw RouterSnapshotError.preflight(.init(
                    code: .duplicateJSONKey, details: .init(stage: stage, version: version)
                ))
            case .limitExceeded(let field, let actual, let maximum):
                throw RouterSnapshotError.preflight(.init(
                    code: .limitExceeded,
                    details: .init(stage: stage, version: version, field: field, actual: actual, maximum: maximum)
                ))
            }
        }
    }
}
