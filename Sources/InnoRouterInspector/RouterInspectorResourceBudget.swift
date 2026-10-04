import InnoRouterCore

public extension RouterInspectorImportLimits {
    init(resourceBudget: RouterResourceBudget) throws {
        try resourceBudget.validateConfiguration()
        self.init(
            maximumEncodedByteCount: resourceBudget.inspectorImport.maximumEncodedBytes,
            maximumEntryCount: resourceBudget.maximumInspectorEntries,
            maximumJSONDepth: resourceBudget.inspectorImport.maximumDepth,
            maximumJSONTokens: resourceBudget.inspectorImport.maximumTokens,
            maximumJSONWorkUnits: resourceBudget.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: resourceBudget.maximumJSONKeyDecodes
        )
    }
}

public extension RouterInspectorRecorder {
    /// Configures this recorder's count retention, import and encoded export
    /// boundaries explicitly. It does not change other stores or subscribers.
    convenience init(resourceBudget: RouterResourceBudget) throws {
        try resourceBudget.validateConfiguration()
        self.init(
            capacity: resourceBudget.maximumRecordedInspectorEntries,
            importLimits: try .init(resourceBudget: resourceBudget),
            exportLimits: .init(maximumEncodedByteCount: resourceBudget.maximumInspectorExportBytes)
        )
    }
}
