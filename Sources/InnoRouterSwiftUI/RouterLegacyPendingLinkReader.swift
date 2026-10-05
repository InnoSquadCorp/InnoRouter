import Foundation
import InnoRouterCore
import InnoRouterDeepLink

/// Explicit version-one reader, including an application-owned route transform.
/// It never assumes that the independent snapshot schema has version one.
/// The whole legacy document is screened before any app `Route.Decodable` runs.
public struct RouterLegacyPendingLinkReader<R: Route>: Sendable {
    private let operation: @Sendable (Data, Date, Duration?, RouterGraphSnapshotLimits, inout RouterJSONWorkBudget) throws -> RouterDurablePendingLink<R>

    private var maximumLegacyJSONDepth: Int?

    public init<Legacy: Route & Codable>(
        decoding: Legacy.Type,
        timestampPolicy: RouterLegacyPendingLinkTimestampPolicy,
        transform: @escaping @Sendable (PendingRouterLink<Legacy>) throws -> PendingRouterLink<R>
    ) {
        operation = { data, now, lifetime, limits, work in
            try RouterPendingLinkCodec<R>.preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", limits: limits, work: &work)
            let marker: RouterPendingLinkFormatMarker = try RouterPendingLinkCodec<R>.read(data, work: &work)
            guard !marker.isGraph else { throw RouterPendingLinkPersistenceError.invalidEnvelope }
            let header: RouterLegacyPendingLinkHeader = try RouterPendingLinkCodec<R>.read(data, work: &work)
            guard header.schemaVersion == 1 else { throw RouterPendingLinkPersistenceError.unsupportedSchemaVersion(header.schemaVersion) }
            let origin: Date
            if let stored = header.originatedAt { origin = stored }
            else {
                switch timestampPolicy {
                case .rejectMissingTimestamp: throw RouterPendingLinkLifetimeFailure(code: .missingOriginTimestamp)
                case .useKnownOrigin(let known): origin = known
                }
            }
            let observed = header.lastObservedAt ?? origin
            try RouterPendingLinkCodec<R>.validateTimestamps(origin: origin, observed: observed, now: now, lifetime: lifetime)
            try Self.validateEncodedShape(data, limits: limits, work: &work)
            let decoded: RouterLegacyPendingLinkEnvelope<Legacy> = try RouterPendingLinkCodec<R>.read(data, work: &work)
            try RouterPendingLinkCodec<R>.charge(1, work: &work)
            let transformed: PendingRouterLink<R>
            do { transformed = try transform(decoded.link) }
            catch { throw RouterPendingLinkPersistenceError.legacyMappingFailed }
            try RouterResourceBudget(snapshot: limits).validate(transformed.plan.state, additionalRouteCount: transformed.matchedRoute == nil ? 1 : 2)
            do { try transformed.plan.state.rejectTransientPresentations(.unsupportedRestoration) }
            catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
            return .init(link: .init(
                url: transformed.url, gatedRoute: transformed.gatedRoute, plan: transformed.plan,
                matchedRoute: transformed.matchedRoute, isRevalidationRequired: true
            ), originatedAt: origin, lastObservedAt: now)
        }
    }

    public init(timestampPolicy: RouterLegacyPendingLinkTimestampPolicy = .rejectMissingTimestamp) where R: Codable {
        self.init(decoding: R.self, timestampPolicy: timestampPolicy, transform: { $0 })
    }

    package static func validateEncodedShape(_ data: Data, limits: RouterGraphSnapshotLimits, work: inout RouterJSONWorkBudget) throws {
    // This first decode has no app code. It checks the recursive legacy
    // topology plus every opaque route's encoded JSON payload bound.
    try RouterPendingLinkCodec<R>.charge(data.count, work: &work)
    let routeBudget = try RouterLegacyRouteAdmission(validatedJSON: data, limits: limits, work: work)
    let decoder = JSONDecoder()
    decoder.userInfo[RouterLegacyRouteAdmission.key] = routeBudget
    let shape: RouterLegacyPendingLinkEnvelope<RouterLegacyRouteShape>
    do { shape = try decoder.decode(RouterLegacyPendingLinkEnvelope<RouterLegacyRouteShape>.self, from: data) }
    catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterPendingLinkPersistenceError.transientPresentation(failure) }
    catch let error as RouterPendingLinkPersistenceError { throw error }
    catch let error as RouterJSONPreflightError {
        switch error {
        case .limitExceeded(let name, let actual, let maximum):
            throw RouterPendingLinkPersistenceError.limitExceeded(name: name, actual: actual, maximum: maximum)
        default: throw RouterPendingLinkPersistenceError.invalidEnvelope
        }
    } catch { throw RouterPendingLinkPersistenceError.invalidEnvelope }
    work = routeBudget.work
    try RouterResourceBudget(snapshot: limits).validate(shape.link.plan.state)
    }

    package func constrained(to budget: RouterResourceBudget) -> Self {
        var copy = self
        copy.maximumLegacyJSONDepth = min(maximumLegacyJSONDepth ?? .max, budget.legacyJSONDepth)
        return copy
    }

    package func decode(_ data: Data, now: Date, lifetime: Duration?, limits: RouterGraphSnapshotLimits, work: inout RouterJSONWorkBudget) throws -> RouterDurablePendingLink<R> {
        let limits = try maximumLegacyJSONDepth.map { try limits.limitingJSONDepth(to: $0) } ?? limits
        return try operation(data, now, lifetime, limits, &work)
    }
}

package struct RouterLegacyPendingLinkEnvelope<R: Route & Codable>: Codable {
    let schemaVersion: Int
    let originatedAt: Date?
    let lastObservedAt: Date?
    let link: PendingRouterLink<R>
}

private struct RouterLegacyPendingLinkHeader: Decodable {
    let schemaVersion: Int
    let originatedAt: Date?
    let lastObservedAt: Date?
}
