import Foundation

/// Explicit app-selected migration from an actual legacy recursive snapshot.
/// The old codec's app version is preserved; no input is assumed to be version 1.
/// A route rename or enum change requires the application's own state transform.
/// This adapter has no storage and cannot overwrite the original bytes.
public struct RouterLegacySnapshotAdapter<R: Route>: Sendable {
    private let operation: @Sendable (Data, RouterGraphSnapshotLimits, Int?, inout RouterJSONWorkBudget) throws -> RouterState<R>

    private var maximumLegacyJSONDepth: Int?

    public init<Legacy: Route & Codable>(
        codec: RouterSnapshotCodec<Legacy>,
        transform: @escaping @Sendable (RouterState<Legacy>) throws -> RouterState<R>
    ) {
        operation = { data, graphLimits, legacyDepth, work in
            let decoded: RouterState<Legacy>
            do { decoded = try codec.boundedForGraphMigration(graphLimits, maximumLegacyJSONDepth: legacyDepth).decodeForGraphMigration(data, work: &work) }
            catch RouterSnapshotError.transientPresentation(let failure) { throw RouterGraphSnapshotError.transientPresentation(failure) }
            catch { throw RouterGraphSnapshotError.legacySnapshotRejected }
            try RouterGraphJSONPreflight.charge(1, work: &work)
            let transformed: RouterState<R>
            do { transformed = try transform(decoded) }
            catch { throw RouterGraphSnapshotError.legacyRouteMappingFailed }
            do { try transformed.rejectTransientPresentations(.unsupportedRestoration) }
            catch let failure as RouterTransientPresentationPersistenceFailure { throw RouterGraphSnapshotError.transientPresentation(failure) }
            return transformed
        }
    }

    /// Keeps the route type when its old Codable payload contract is unchanged.
    public init(codec: RouterSnapshotCodec<R>) where R: Codable {
        self.init(codec: codec, transform: { $0 })
    }

    package func constrained(to budget: RouterResourceBudget) -> Self {
        var copy = self
        copy.maximumLegacyJSONDepth = min(maximumLegacyJSONDepth ?? .max, budget.legacyJSONDepth)
        return copy
    }

    package func decode(_ data: Data, limits: RouterGraphSnapshotLimits, work: inout RouterJSONWorkBudget) throws -> RouterState<R> {
        try operation(data, limits, maximumLegacyJSONDepth, &work)
    }
}
