public extension RouterResourceBudget {
    /// Raw configuration values are retained at construction, never clamped.
    /// Every resource owner checks this before deriving limits or starting work.
    /// Zero is allowed only for capacities, work accounting, and deadlines that
    /// can meaningfully admit no work. Duration is finite by its Swift value type.
    func validateConfiguration() throws(RouterResourceLimitFailure) {
        let nonnegative: [(String, Int?)] = [
            ("maximumPendingRequests", maximumPendingRequests),
            ("maximumDeferrals", maximumDeferrals),
            ("maximumActivePolicyOperations", maximumActivePolicyOperations),
            ("maximumActiveRestorationOperations", maximumActiveRestorationOperations),
            ("maximumJSONWorkUnits", maximumJSONWorkUnits),
            ("maximumJSONKeyDecodes", maximumJSONKeyDecodes),
        ]
        for (field, value) in nonnegative {
            if let value, value < 0 {
                throw .invalidConfiguration(field: field, actual: value, minimum: 0)
            }
        }
        let positive = [
            ("legacyJSONDepth", legacyJSONDepth),
            ("maximumScenarioSteps", maximumScenarioSteps),
            ("maximumInspectorEntries", maximumInspectorEntries),
            ("maximumRecordedInspectorEntries", maximumRecordedInspectorEntries),
            ("maximumInspectorExportBytes", maximumInspectorExportBytes),
        ]
        for (field, value) in positive where value <= 0 {
            throw .invalidConfiguration(field: field, actual: value, minimum: 1)
        }
        let durations: [(String, Duration?)] = [
            ("policyTimeout", policyTimeout), ("deferralLifetime", deferralLifetime),
            ("durablePendingLifetime", durablePendingLifetime),
        ]
        for (field, value) in durations {
            if let value, value < .zero {
                let components = value.components
                let usesSeconds = components.seconds < 0
                let component = usesSeconds ? components.seconds : components.attoseconds
                throw .invalidConfiguration(
                    field: field + (usesSeconds ? ".seconds" : ".attoseconds"),
                    actual: Int(clamping: component), minimum: 0
                )
            }
        }
        try scenarioImport.validateConfiguration(fieldPrefix: "scenarioImport.")
        try inspectorImport.validateConfiguration(fieldPrefix: "inspectorImport.")
    }
}

public extension RouterJSONImportBudget {
    /// Invalid byte, depth, or token settings are rejected rather than expanded.
    func validateConfiguration() throws(RouterResourceLimitFailure) {
        try validateConfiguration(fieldPrefix: "")
    }
}

extension RouterJSONImportBudget {
    func validateConfiguration(fieldPrefix: String) throws(RouterResourceLimitFailure) {
        let positive = [
            ("maximumEncodedBytes", maximumEncodedBytes),
            ("maximumDepth", maximumDepth),
            ("maximumTokens", maximumTokens),
        ]
        for (field, value) in positive where value <= 0 {
            throw .invalidConfiguration(field: fieldPrefix + field, actual: value, minimum: 1)
        }
    }
}

private extension RouterResourceLimitFailure {
    static func invalidConfiguration(field: String, actual: Int, minimum: Int) -> Self {
        Self(
            code: .invalidConfiguration, resource: "configuration." + field,
            actual: actual, maximum: .max, minimum: minimum
        )
    }
}
