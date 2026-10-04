import InnoRouterCore

public extension RouterPendingLinkCodec {
    /// The durable owner shares finite structure, byte, logical-work and expiry
    /// settings, while the app graph codec retains every stricter limit.
    init(
        graphCodec: RouterGraphSnapshotCodec<R>,
        resourceBudget: RouterResourceBudget,
        migrations: [RouterPendingLinkMigration] = [],
        legacyReader: RouterLegacyPendingLinkReader<R>? = nil
    ) throws {
        try resourceBudget.validateConfiguration()
        try self.init(
            graphCodec: graphCodec.constrained(to: resourceBudget),
            lifetime: resourceBudget.durablePendingLifetime, migrations: migrations, legacyReader: legacyReader?.constrained(to: resourceBudget),
            maximumJSONWorkUnits: resourceBudget.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: resourceBudget.maximumJSONKeyDecodes
        )
    }

    /// Explicit legacy format selection; no app schema or missing timestamp is
    /// guessed. A malformed shared configuration is rejected at construction.
    init(
        resourceBudget: RouterResourceBudget,
        legacyTimestampPolicy: RouterLegacyPendingLinkTimestampPolicy = .rejectMissingTimestamp
    ) throws where R: Codable {
        try resourceBudget.validateConfiguration()
        self.init(
            legacyTimestampPolicy: legacyTimestampPolicy, limits: try resourceBudget.snapshot.limitingJSONDepth(to: resourceBudget.legacyJSONDepth),
            lifetime: resourceBudget.durablePendingLifetime,
            maximumJSONWorkUnits: resourceBudget.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: resourceBudget.maximumJSONKeyDecodes
        )
    }
}
