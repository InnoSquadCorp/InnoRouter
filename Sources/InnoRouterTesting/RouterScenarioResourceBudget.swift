import Foundation
import InnoRouterCore

public extension RouterScenarioFixture {
    /// Uses the scenario owner's byte/depth/token/step limits and the common
    /// logical-work caps before any application's Decodable implementation.
    static func decode(from data: Data, resourceBudget: RouterResourceBudget) throws -> Self {
        try resourceBudget.validateConfiguration()
        return try decode(
            from: data,
            maximumByteCount: resourceBudget.scenarioImport.maximumEncodedBytes,
            maximumStepCount: resourceBudget.maximumScenarioSteps,
            maximumJSONDepth: resourceBudget.scenarioImport.maximumDepth,
            maximumJSONTokens: resourceBudget.scenarioImport.maximumTokens,
            maximumJSONWorkUnits: resourceBudget.maximumJSONWorkUnits,
            maximumJSONKeyDecodes: resourceBudget.maximumJSONKeyDecodes
        )
    }
}
