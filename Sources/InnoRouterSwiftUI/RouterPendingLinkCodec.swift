import Foundation
import InnoRouterCore
import InnoRouterDeepLink

/// Durable intent metadata, separate from link equality and live authority.
/// These timestamps never represent an authentication grant or incarnation.
public struct RouterDurablePendingLink<R: Route>: Sendable, Equatable {
    public let link: PendingRouterLink<R>
    public let originatedAt: Date
    public let lastObservedAt: Date

    public init(link: PendingRouterLink<R>, originatedAt: Date, lastObservedAt: Date) {
        self.link = link
        self.originatedAt = originatedAt
        self.lastObservedAt = lastObservedAt
    }
}

/// Historical version-one files did not include a lifetime origin. Applications
/// must explicitly supply a known origin; loading never invents a fresh one.
public enum RouterLegacyPendingLinkTimestampPolicy: Sendable, Equatable {
    case rejectMissingTimestamp
    case useKnownOrigin(Date)
}

public enum RouterPendingLinkPersistenceError: Error, Sendable, Hashable {
    case unsupportedSchemaVersion(Int)
    case unsupportedFormatVersion(Int)
    case schemaMismatch
    case invalidEnvelope
    case malformedJSON
    case duplicateJSONKey
    case limitExceeded(name: String, actual: Int, maximum: Int)
    case legacyReaderRequired
    case legacyMappingFailed
    case encodingFailed
    case transientPresentation(RouterTransientPresentationPersistenceFailure)
    case invalidMigration(from: Int, to: Int)
    case duplicateMigration(Int)
    case missingMigration(from: Int, current: Int)
    case migrationFailed(from: Int, to: Int)
}

/// A bounded flat-graph pending-link format for routes that need not be Codable.
/// This stores intent only. Restored values always require fresh URL/origin,
/// declaration catalog, host, and authorization admission on the existing Store.
///
/// Library format and application schema are separate. Older pending schemas
/// require an explicit adjacent migration chain, never an inferred case rename.
/// Each migration output is bounded before another migration or app route decode.
/// Bounds are provisional logical limits, not measured CPU/RSS guarantees.
public struct RouterPendingLinkCodec<R: Route>: Sendable {
    public static var formatVersion: Int { 1 }
    public let limits: RouterGraphSnapshotLimits
    public let transientPresentations: RouterTransientPresentationPersistencePolicy
    /// Provisional 24-hour lifetime. Explicit `nil` opts out of age expiry;
    /// malformed timestamps and clock reversal still fail closed.
    public let lifetime: Duration?
    private let encodeOperation: @Sendable (RouterDurablePendingLink<R>) throws -> Data
    private let decodeOperation: @Sendable (Data, Date) throws -> RouterDurablePendingLink<R>

    public init(
        graphCodec: RouterGraphSnapshotCodec<R>,
        lifetime: Duration? = .seconds(24 * 60 * 60),
        migrations: [RouterPendingLinkMigration] = [],
        legacyReader: RouterLegacyPendingLinkReader<R>? = nil,
        maximumJSONWorkUnits: Int? = nil,
        maximumJSONKeyDecodes: Int? = nil
    ) throws {
        try RouterResourceBudget(snapshot: graphCodec.limits, durablePendingLifetime: lifetime,
                                 maximumJSONWorkUnits: maximumJSONWorkUnits, maximumJSONKeyDecodes: maximumJSONKeyDecodes)
            .validateConfiguration()
        var indexed: [Int: RouterPendingLinkMigration] = [:]
        for migration in migrations {
            guard migration.fromVersion > 0, migration.fromVersion < graphCodec.schemaVersion,
                  migration.toVersion == migration.fromVersion + 1 else {
                throw RouterPendingLinkPersistenceError.invalidMigration(from: migration.fromVersion, to: migration.toVersion)
            }
            guard indexed.updateValue(migration, forKey: migration.fromVersion) == nil else {
                throw RouterPendingLinkPersistenceError.duplicateMigration(migration.fromVersion)
            }
        }
        let migrationsByVersion = indexed
        let limits = graphCodec.limits
        let workLimits = Self.workLimits(limits, units: maximumJSONWorkUnits, keys: maximumJSONKeyDecodes)
        self.limits = limits
        self.transientPresentations = graphCodec.transientPresentations
        self.lifetime = lifetime
        let lifetime = self.lifetime
        encodeOperation = { record in
            try Self.validateLifetime(record, now: record.lastObservedAt, lifetime: lifetime)
            var work = RouterJSONWorkBudget(limits: workLimits)
            try Self.check(record.link.url.absoluteString.utf8.count, maximum: limits.maximumPayloadBytes, name: "urlBytes")
            let encoded = try graphCodec.encodePendingGraph(record.link.plan.state,
                additionalRoutes: [record.link.gatedRoute] + (record.link.matchedRoute.map { [$0] } ?? []), work: &work)
            let graph = encoded.plan
            let gated = encoded.payloads[0]
            let matched = encoded.payloads.count > 1 ? encoded.payloads[1] : nil
            let payload = RouterPendingLinkGraphPayload(url: record.link.url, plan: graph, gatedRoute: gated, matchedRoute: matched)
            let payloadData = try Self.json(payload, work: &work)
            try Self.preflight(payloadData, maximum: limits.maximumPayloadBytes, name: "payloadBytes", limits: limits, work: &work)
            let envelope = RouterPendingLinkGraphEnvelope(
                formatVersion: Self.formatVersion, schemaID: graphCodec.schemaID, schemaVersion: graphCodec.schemaVersion,
                originatedAt: record.originatedAt, lastObservedAt: record.lastObservedAt, payload: payloadData
            )
            let data = try Self.json(envelope, work: &work)
            try Self.preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", limits: limits, work: &work)
            return data
        }
        decodeOperation = { data, now in
            var work = RouterJSONWorkBudget(limits: workLimits)
            try Self.preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", limits: limits, work: &work)
            let marker: RouterPendingLinkFormatMarker = try Self.read(data, work: &work)
            if !marker.isGraph {
                guard let legacyReader else { throw RouterPendingLinkPersistenceError.legacyReaderRequired }
                let record = try legacyReader.decode(data, now: now, lifetime: lifetime, limits: limits, work: &work)
                // The explicit app mapping is still bounded by the destination
                // graph codec. No write occurs until the caller requests one.
                _ = try graphCodec.encodePendingGraph(record.link.plan.state,
                    additionalRoutes: [record.link.gatedRoute] + (record.link.matchedRoute.map { [$0] } ?? []), work: &work)
                return record
            }
            let envelope: RouterPendingLinkGraphEnvelope = try Self.read(data, work: &work)
            guard envelope.formatVersion == Self.formatVersion else {
                throw RouterPendingLinkPersistenceError.unsupportedFormatVersion(envelope.formatVersion)
            }
            guard envelope.schemaID == graphCodec.schemaID else { throw RouterPendingLinkPersistenceError.schemaMismatch }
            guard envelope.schemaVersion > 0, envelope.schemaVersion <= graphCodec.schemaVersion else {
                throw RouterPendingLinkPersistenceError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            try Self.validateTimestamps(origin: envelope.originatedAt, observed: envelope.lastObservedAt, now: now, lifetime: lifetime)
            var payloadData = envelope.payload
            var version = envelope.schemaVersion
            var payload = try Self.screenPayload(payloadData, graphCodec: graphCodec, work: &work)
            while version < graphCodec.schemaVersion {
                guard let migration = migrationsByVersion[version] else {
                    throw RouterPendingLinkPersistenceError.missingMigration(from: version, current: graphCodec.schemaVersion)
                }
                try Self.charge(payloadData.count, work: &work)
                do { payloadData = try migration.transform(payloadData) }
                catch { throw RouterPendingLinkPersistenceError.migrationFailed(from: version, to: migration.toVersion) }
                payload = try Self.screenPayload(payloadData, graphCodec: graphCodec, work: &work)
                version = migration.toVersion
            }
            let routePayloads = [payload.gatedRoute] + (payload.matchedRoute.map { [$0] } ?? [])
            try Self.checkRoutes(routePayloads, limits: limits, work: &work)
            for route in routePayloads { try graphCodec.routes.validate(route) }
            // Preparation admits the whole graph and all its route keys before
            // either standalone target or plan application decoder may run.
            let prepared = try graphCodec.prepareGraphDecode(payload.plan, work: &work, additionalRoutePayloads: routePayloads)
            let state = try prepared()
            let gated = try graphCodec.routes.decode(payload.gatedRoute)
            let matched = try payload.matchedRoute.map { try graphCodec.routes.decode($0) }
            return .init(link: .init(
                url: payload.url, gatedRoute: gated, plan: .init(state: state),
                matchedRoute: matched, requiresRevalidation: true
            ), originatedAt: envelope.originatedAt, lastObservedAt: max(now, envelope.lastObservedAt))
        }
    }

    /// Explicit reader/writer for the historical fixed version-one envelope.
    /// This does not guess an application's snapshot schema or stable keys.
    public init(
        legacyTimestampPolicy: RouterLegacyPendingLinkTimestampPolicy = .rejectMissingTimestamp,
        limits: RouterGraphSnapshotLimits = .provisional,
        lifetime: Duration? = .seconds(24 * 60 * 60),
        maximumJSONWorkUnits: Int? = nil,
        maximumJSONKeyDecodes: Int? = nil,
        transientPresentations: RouterTransientPresentationPersistencePolicy = .reject
    ) where R: Codable {
        self.limits = limits
        self.transientPresentations = transientPresentations
        self.lifetime = lifetime
        let lifetime = self.lifetime
        let workLimits = Self.workLimits(limits, units: maximumJSONWorkUnits, keys: maximumJSONKeyDecodes)
        let reader = RouterLegacyPendingLinkReader<R>(timestampPolicy: legacyTimestampPolicy)
        let configuration = Result {
            try RouterResourceBudget(snapshot: limits, durablePendingLifetime: lifetime,
                                     maximumJSONWorkUnits: maximumJSONWorkUnits, maximumJSONKeyDecodes: maximumJSONKeyDecodes)
                .validateConfiguration()
        }
        encodeOperation = { record in
            try configuration.get()
            try Self.validateLifetime(record, now: record.lastObservedAt, lifetime: lifetime)
            try RouterResourceBudget(snapshot: limits).validate(record.link.plan.state, additionalRouteCount: record.link.matchedRoute == nil ? 1 : 2)
            let projected = try record.link.plan.state.preparingTransientPersistence(transientPresentations)
            let link = PendingRouterLink(
                url: record.link.url, gatedRoute: record.link.gatedRoute, plan: RouterPlan(state: projected),
                matchedRoute: record.link.matchedRoute, requiresRevalidation: record.link.requiresRevalidation
            )
            var work = RouterJSONWorkBudget(limits: workLimits)
            let data = try Self.json(RouterLegacyPendingLinkEnvelope(
                schemaVersion: 1, originatedAt: record.originatedAt,
                lastObservedAt: record.lastObservedAt, link: link
            ), work: &work)
            try Self.preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", limits: limits, work: &work)
            try RouterLegacyPendingLinkReader<R>.validateEncodedShape(data, limits: limits, work: &work)
            return data
        }
        decodeOperation = { data, now in
            try configuration.get()
            var work = RouterJSONWorkBudget(limits: workLimits)
            return try reader.decode(data, now: now, lifetime: lifetime, limits: limits, work: &work)
        }
    }

    public func encode(_ record: RouterDurablePendingLink<R>) throws -> Data {
        do { return try encodeOperation(record) }
        catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
        catch let error as RouterGraphSnapshotError {
            if let failure = error.details.transientPresentation { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
            throw error
        }
    }
    public func decode(_ data: Data, now: Date = Date()) throws -> RouterDurablePendingLink<R> {
        do { return try decodeOperation(data, now) }
        catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
        catch let error as RouterGraphSnapshotError {
            if let failure = error.details.transientPresentation { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
            throw error
        }
    }

    package func validateLifetime(_ record: RouterDurablePendingLink<R>, now: Date) throws {
        try Self.validateLifetime(record, now: now, lifetime: lifetime)
    }

    package static func validateLifetime(_ record: RouterDurablePendingLink<R>, now: Date, lifetime: Duration?) throws {
        try validateTimestamps(origin: record.originatedAt, observed: record.lastObservedAt, now: now, lifetime: lifetime)
    }

    package static func validateTimestamps(origin: Date, observed: Date, now: Date, lifetime: Duration?) throws {
        guard origin.timeIntervalSinceReferenceDate.isFinite,
              observed.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite,
              observed >= origin else { throw RouterPendingLinkLifetimeFailure(code: .invalidTimestamp) }
        guard now >= observed else { throw RouterPendingLinkLifetimeFailure(code: .clockReversed) }
        if let lifetime {
            let components = lifetime.components
            let age = Double(components.seconds) + Double(components.attoseconds) / 1e18
            guard now.timeIntervalSince(origin) < age else { throw RouterPendingLinkLifetimeFailure(code: .expired) }
        }
    }

    package static func workLimits(_ limits: RouterGraphSnapshotLimits, units: Int?, keys: Int?) -> RouterJSONWorkLimits {
        let derived = RouterJSONWorkLimits.derived(maximumBytes: limits.maximumEncodedBytes, maximumTokens: limits.maximumJSONTokens)
        return .init(maximumWorkUnits: units ?? derived.maximumWorkUnits, maximumKeyDecodes: keys ?? derived.maximumKeyDecodes)
    }

    package static func preflight(_ data: Data, maximum: Int, name: String, limits: RouterGraphSnapshotLimits, work: inout RouterJSONWorkBudget) throws {
        do {
            let used = try RouterJSONPreflight.validate(data, maximumBytes: maximum, maximumDepth: limits.maximumJSONDepth,
                maximumTokens: limits.maximumJSONTokens, byteName: name, workLimits: work.limits, consumedWork: work.result)
            work = try .init(limits: work.limits, consumed: used)
        } catch let error as RouterJSONPreflightError { throw failure(error) }
    }

    package static func charge(_ units: Int, work: inout RouterJSONWorkBudget) throws {
        do { try work.charge(units) }
        catch let error as RouterJSONPreflightError { throw failure(error) }
    }

    package static func check(_ actual: Int, maximum: Int, name: String) throws {
        guard actual <= maximum else { throw RouterPendingLinkPersistenceError.limitExceeded(name: name, actual: actual, maximum: maximum) }
    }

    private static func screenPayload(_ data: Data, graphCodec: RouterGraphSnapshotCodec<R>, work: inout RouterJSONWorkBudget) throws -> RouterPendingLinkGraphPayload {
        try preflight(data, maximum: graphCodec.limits.maximumPayloadBytes, name: "payloadBytes", limits: graphCodec.limits, work: &work)
        let payload: RouterPendingLinkGraphPayload = try read(data, work: &work)
        try checkRoutes([payload.gatedRoute] + (payload.matchedRoute.map { [$0] } ?? []), limits: graphCodec.limits, work: &work)
        // Intermediate outer payloads need bounded library structure, not the
        // final app schema/route keys. Final preparation runs graph migrations once.
        try graphCodec.screenGraphStructure(payload.plan, work: &work)
        return payload
    }

    private static func checkRoutes(_ payloads: [RouterGraphRoutePayload], limits: RouterGraphSnapshotLimits, work: inout RouterJSONWorkBudget) throws {
        var total = 0
        for payload in payloads {
            try check(payload.data.count, maximum: limits.maximumRoutePayloadBytes, name: "routePayloadBytes")
            total = try RouterResourceBudget.addingResourceCount(total, payload.data.count, maximum: limits.maximumPayloadBytes, resource: "pending.routePayloadBytes")
            try charge(payload.data.count, work: &work)
            try charge(payload.stableKey.utf8.count, work: &work)
        }
    }

    package static func json(_ value: some Encodable, work: inout RouterJSONWorkBudget) throws -> Data {
        try charge(1, work: &work)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) }
        catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
        catch { throw RouterPendingLinkPersistenceError.encodingFailed }
    }

    package static func read<Value: Decodable>(_ data: Data, work: inout RouterJSONWorkBudget) throws -> Value {
        try charge(data.count, work: &work)
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
        catch { throw RouterPendingLinkPersistenceError.invalidEnvelope }
    }

    private static func failure(_ error: RouterJSONPreflightError) -> RouterPendingLinkPersistenceError {
        switch error {
        case .malformedJSON: .malformedJSON
        case .duplicateJSONKey: .duplicateJSONKey
        case .limitExceeded(let name, let actual, let maximum): .limitExceeded(name: name, actual: actual, maximum: maximum)
        }
    }
}

package struct RouterPendingLinkGraphEnvelope: Codable, Sendable {
    var formatVersion: Int
    var schemaID: String
    var schemaVersion: Int
    var originatedAt: Date
    var lastObservedAt: Date
    var payload: Data
}

package struct RouterPendingLinkGraphPayload: Codable, Sendable {
    var url: URL
    var plan: Data
    var gatedRoute: RouterGraphRoutePayload
    var matchedRoute: RouterGraphRoutePayload?
}

package struct RouterPendingLinkFormatMarker: Decodable {
    let isGraph: Bool
    private enum CodingKeys: String, CodingKey { case formatVersion, schemaID, payload }
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isGraph = container.contains(.formatVersion) || container.contains(.schemaID) || container.contains(.payload)
    }
}

/// One explicit adjacent transform of the pending payload JSON (URL, graph plan,
/// and stable target descriptors). Lifetime metadata lives outside this payload,
/// so a schema migration cannot silently renew the durable intent's age.
public struct RouterPendingLinkMigration: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    private let operation: @Sendable (Data) throws -> Data
    public init(from fromVersion: Int, to toVersion: Int, transform: @escaping @Sendable (Data) throws -> Data) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        operation = transform
    }
    package func transform(_ data: Data) throws -> Data { try operation(data) }
}
