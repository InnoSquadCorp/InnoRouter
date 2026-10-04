import Foundation
import InnoRouterCore

enum RouterScenarioImportPreflight {
    static func validate(
        _ data: Data,
        maximumBytes: Int,
        maximumSteps: Int,
        maximumDepth: Int,
        maximumTokens: Int,
        maximumWorkUnits: Int? = nil,
        maximumKeyDecodes: Int? = nil
    ) throws {
        do {
            let derived = RouterJSONWorkLimits.derived(maximumBytes: maximumBytes, maximumTokens: maximumTokens)
            let limits = RouterJSONWorkLimits(
                maximumWorkUnits: maximumWorkUnits ?? derived.maximumWorkUnits,
                maximumKeyDecodes: maximumKeyDecodes ?? derived.maximumKeyDecodes
            )
            let usage = try RouterJSONPreflight.validate(
                data, maximumBytes: maximumBytes, maximumDepth: maximumDepth,
                maximumTokens: maximumTokens, byteName: "encodedBytes",
                requiredRootArrayLimits: ["steps": maximumSteps], workLimits: limits
            )
            var work = try RouterJSONWorkBudget(limits: limits, consumed: usage)
            try work.charge(data.count) // Reserve the final typed decoder pass before app routes.

        } catch let error as RouterJSONPreflightError {
            switch error {
            case .limitExceeded("encodedBytes", let actual, let maximum):
                throw RouterScenarioFixtureError.encodedDataTooLarge(actual: actual, maximum: maximum)
            case .limitExceeded("steps", let actual, let maximum):
                throw RouterScenarioFixtureError.tooManySteps(actual: actual, maximum: maximum)
            case .limitExceeded("jsonDepth", let actual, let maximum):
                throw RouterScenarioFixtureError.jsonDepthExceeded(actual: actual, maximum: maximum)
            case .limitExceeded("jsonTokens", let actual, let maximum):
                throw RouterScenarioFixtureError.jsonTokenLimitExceeded(actual: actual, maximum: maximum)
            case .limitExceeded(let field, let actual, let maximum) where field == "jsonWorkUnits" || field == "jsonKeyDecodes":
                throw RouterScenarioFixtureError.resourceLimit(.init(resource: field, actual: actual, maximum: maximum))
            case .malformedJSON, .duplicateJSONKey, .limitExceeded:
                throw RouterScenarioFixtureError.malformedFixtureEnvelope
            }
        }
    }
}
