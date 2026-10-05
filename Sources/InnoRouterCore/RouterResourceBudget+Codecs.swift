import Foundation

public extension RouterGraphSnapshotCodec {
    /// Applies the same explicit budget to graph structure, payloads and logical
    /// JSON work. App codec execution remains cooperative and app-owned.
    init(
        schemaID: String,
        schemaVersion: Int,
        routes: RouterGraphRouteCodec<R>,
        resourceBudget: RouterResourceBudget,
        migrations: [RouterGraphSnapshotMigration] = [],
        legacyAdapter: RouterLegacySnapshotAdapter<R>? = nil,
        transientPresentations: RouterTransientPresentationPersistencePolicy = .reject
    ) throws {
        try resourceBudget.validateConfiguration()
        try self.init(
            schemaID: schemaID, schemaVersion: schemaVersion, routes: routes,
            limits: resourceBudget.snapshot, migrations: migrations, legacyAdapter: legacyAdapter,
            maximumJSONWorkUnits: resourceBudget.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: resourceBudget.maximumJSONKeyDecodes,
            transientPresentations: transientPresentations
        )
    }
}

package extension RouterResourceBudget {
    func jsonWorkLimits(maximumBytes: Int, maximumTokens: Int) -> RouterJSONWorkLimits {
        let derived = RouterJSONWorkLimits.derived(maximumBytes: maximumBytes, maximumTokens: maximumTokens)
        return .init(
            maximumWorkUnits: maximumJSONWorkUnits ?? derived.maximumWorkUnits,
            maximumKeyDecodes: maximumJSONKeyDecodes ?? derived.maximumKeyDecodes
        )
    }
}

public extension RouterSnapshotCodec {
    /// Applies the common persistence limits while retaining the legacy wire
    /// format's explicit JSON depth and the app's actual schema version.
    init(
        currentVersion: Int,
        migrations: [RouterSnapshotMigration] = [],
        resourceBudget: RouterResourceBudget,
        transientPresentations: RouterTransientPresentationPersistencePolicy = .reject
    ) throws {
        try resourceBudget.validateConfiguration()
        try self.init(currentVersion: currentVersion, migrations: migrations, limits: .init(
            maximumEncodedByteCount: resourceBudget.snapshot.maximumEncodedBytes,
            maximumPayloadByteCount: resourceBudget.snapshot.maximumPayloadBytes,
            maximumJSONDepth: resourceBudget.legacyJSONDepth,
            maximumJSONTokens: resourceBudget.snapshot.maximumJSONTokens,
            maximumJSONWorkUnits: resourceBudget.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: resourceBudget.maximumJSONKeyDecodes
        ), transientPresentations: transientPresentations)
        setResourceLimits(resourceBudget.snapshot)
    }
}
