import Foundation

package extension RouterGraphSnapshotCodec {
    /// An adapter cannot silently widen its Store owner's admitted resources.
    /// Explicit opt-out requires both owners to permit the larger operation.
    func constrained(to budget: RouterResourceBudget) throws -> Self {
        try budget.validateConfiguration()
        let limits = try limits.intersecting(budget.snapshot)
        let ownerWork = budget.jsonWorkLimits(
            maximumBytes: limits.maximumEncodedBytes, maximumTokens: limits.maximumJSONTokens
        )
        return try Self(
            schemaID: schemaID, schemaVersion: schemaVersion, routes: routes,
            limits: limits, migrations: Array(migrations.values), legacyAdapter: legacyAdapter?.constrained(to: budget),
            maximumJSONWorkUnits: min(jsonWorkLimits.maximumWorkUnits, ownerWork.maximumWorkUnits),
            maximumJSONKeyDecodes: min(jsonWorkLimits.maximumKeyDecodes, ownerWork.maximumKeyDecodes),
            transientPresentations: transientPresentations
        )
    }
}

package extension RouterSnapshotCodec {
    func constrained(to budget: RouterResourceBudget) throws -> Self {
        try budget.validateConfiguration()
        let graph = try resourceLimits?.intersecting(budget.snapshot) ?? budget.snapshot
        let ownerWork = budget.jsonWorkLimits(
            maximumBytes: graph.maximumEncodedBytes, maximumTokens: graph.maximumJSONTokens
        )
        let ownWork = limits.map {
            RouterJSONWorkLimits.derived(maximumBytes: $0.maximumEncodedByteCount, maximumTokens: $0.maximumJSONTokens)
        }
        let bounded = try RouterSnapshotLimits(
            maximumEncodedByteCount: min(limits?.maximumEncodedByteCount ?? .max, graph.maximumEncodedBytes),
            maximumPayloadByteCount: min(limits?.maximumPayloadByteCount ?? .max, graph.maximumPayloadBytes),
            maximumJSONDepth: min(limits?.maximumJSONDepth ?? .max, budget.legacyJSONDepth),
            maximumJSONTokens: min(limits?.maximumJSONTokens ?? .max, graph.maximumJSONTokens),
            maximumJSONWorkUnits: min(limits?.maximumJSONWorkUnits ?? ownWork?.maximumWorkUnits ?? .max, ownerWork.maximumWorkUnits),
            maximumJSONKeyDecodes: min(limits?.maximumJSONKeyDecodes ?? ownWork?.maximumKeyDecodes ?? .max, ownerWork.maximumKeyDecodes)
        )
        var codec = try Self(currentVersion: currentVersion, migrations: Array(migrations.values), limits: bounded, transientPresentations: transientPresentations)
        codec.setResourceLimits(graph)
        return codec
    }
}
