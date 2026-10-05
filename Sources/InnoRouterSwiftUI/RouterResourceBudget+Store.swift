import InnoRouterCore

extension RouterResourceBudget {
    /// Keeps adapter limits unchanged while legacy Store properties remain
    /// writable aliases for the Store-owned portion of the shared budget.
    func replacingStoreLimits(
        maximumPendingRequests: Int,
        maximumDeferrals: Int,
        maximumActivePolicyOperations: Int?,
        maximumActiveRestorationOperations: Int?,
        policyTimeout: Duration?,
        deferralLifetime: Duration?
    ) -> Self {
        Self(
            snapshot: snapshot,
            maximumPendingRequests: maximumPendingRequests,
            maximumDeferrals: maximumDeferrals,
            maximumActivePolicyOperations: maximumActivePolicyOperations,
            maximumActiveRestorationOperations: maximumActiveRestorationOperations,
            policyTimeout: policyTimeout,
            deferralLifetime: deferralLifetime,
            durablePendingLifetime: durablePendingLifetime,
            legacyJSONDepth: legacyJSONDepth,
            scenarioImport: scenarioImport,
            inspectorImport: inspectorImport,
            maximumScenarioSteps: maximumScenarioSteps,
            maximumInspectorEntries: maximumInspectorEntries,
            maximumRecordedInspectorEntries: maximumRecordedInspectorEntries,
            maximumInspectorExportBytes: maximumInspectorExportBytes,
            maximumJSONWorkUnits: maximumJSONWorkUnits,
            maximumJSONKeyDecodes: maximumJSONKeyDecodes
        )
    }
}
