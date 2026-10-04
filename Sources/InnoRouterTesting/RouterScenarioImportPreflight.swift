import Foundation
import InnoRouterCore

enum RouterScenarioImportPreflight {
    private struct Header: Decodable { let formatVersion: Int }

    /// The shared baseline covered the original import passes. Classification,
    /// opaque shape and descriptor validation add three reserved byte passes.
    /// Explicit user limits are never raised. Overflow keeps a finite cap.
    static func derivedWorkLimits(maximumBytes: Int, maximumTokens: Int) -> RouterJSONWorkLimits {
        let baseline = RouterJSONWorkLimits.derived(maximumBytes: maximumBytes, maximumTokens: maximumTokens)
        let extra = max(0, maximumBytes).multipliedReportingOverflow(by: 3)
        let total = baseline.maximumWorkUnits.addingReportingOverflow(extra.partialValue)
        return .init(
            maximumWorkUnits: extra.overflow || total.overflow ? Int.max : total.partialValue,
            maximumKeyDecodes: baseline.maximumKeyDecodes
        )
    }

    @discardableResult
    static func validate(
        _ data: Data,
        maximumBytes: Int,
        maximumSteps: Int,
        maximumDepth: Int,
        maximumTokens: Int,
        maximumWorkUnits: Int? = nil,
        maximumKeyDecodes: Int? = nil,
        consumedWork: RouterJSONWorkResult? = nil
    ) throws -> Int {
        do {
            let derived = derivedWorkLimits(maximumBytes: maximumBytes, maximumTokens: maximumTokens)
            let limits = RouterJSONWorkLimits(
                maximumWorkUnits: maximumWorkUnits ?? derived.maximumWorkUnits,
                maximumKeyDecodes: maximumKeyDecodes ?? derived.maximumKeyDecodes
            )
            let usage = try RouterJSONPreflight.validate(
                data, maximumBytes: maximumBytes, maximumDepth: maximumDepth,
                maximumTokens: maximumTokens, byteName: "encodedBytes",
                requiredRootArrayLimits: ["steps": maximumSteps], workLimits: limits,
                consumedWork: consumedWork
            )
            var work = try RouterJSONWorkBudget(limits: limits, consumed: usage)
            // Every additional Foundation pass is reserved against the same
            // ledger. The opaque route never invokes application Decodable.
            try work.charge(data.count)
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.formatVersion == 8 || header.formatVersion == 9 else {
                throw RouterScenarioFixtureError.unsupportedFormatVersion(header.formatVersion)
            }
            try work.charge(data.count)
            let shape = try RouterTransientDescriptorTransport.decoder(formatVersion: header.formatVersion)
                .decode(RouterScenarioFixture<RouterTransientOpaqueRoute>.self, from: data)
            try work.charge(data.count) // Reserve structural descriptor validation.
            try shape.validateTransportStructure()
            try work.charge(data.count) // Reserve final typed decode before app routes.
            return header.formatVersion

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
