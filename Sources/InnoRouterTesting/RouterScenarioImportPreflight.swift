import Foundation
import InnoRouterCore

enum RouterScenarioImportPreflight {
    static func validate(
        _ data: Data,
        maximumBytes: Int,
        maximumSteps: Int,
        maximumDepth: Int,
        maximumTokens: Int
    ) throws {
        do {
            try RouterJSONPreflight.validate(
                data, maximumBytes: maximumBytes, maximumDepth: maximumDepth,
                maximumTokens: maximumTokens, byteName: "encodedBytes",
                requiredRootArrayLimits: ["steps": maximumSteps]
            )
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
            case .malformedJSON, .duplicateJSONKey, .limitExceeded:
                throw RouterScenarioFixtureError.malformedFixtureEnvelope
            }
        }
    }
}
