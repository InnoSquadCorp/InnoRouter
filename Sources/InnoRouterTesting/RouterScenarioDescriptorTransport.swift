import Foundation
import InnoRouterCore

public extension RouterScenarioFixture {
    /// Exports a bounded diagnostic fixture, including inert alert/dialog
    /// descriptors. It never exports typed result values, tasks, callbacks or
    /// runtime authority. Use `decode(from:)` to import; this is not a snapshot.
    /// Bare JSONEncoder remains navigation-only.
    ///
    /// Complete original states and actions are admitted before any application
    /// Encodable callback. Encoded output then uses the scenario byte, step,
    /// depth, token and cumulative logical-work limits. Route encoder memory
    /// and execution time are outside these logical resource guarantees.
    func encode(
        resourceBudget: RouterResourceBudget = .provisional,
        outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    ) throws -> Data {
        try resourceBudget.validateConfiguration()
        guard steps.count <= resourceBudget.maximumScenarioSteps else {
            throw RouterScenarioFixtureError.tooManySteps(
                actual: steps.count, maximum: resourceBudget.maximumScenarioSteps
            )
        }
        do {
            // A zero work allowance cannot enter an application encoder.
            let derived = RouterScenarioImportPreflight.derivedWorkLimits(
                maximumBytes: resourceBudget.scenarioImport.maximumEncodedBytes,
                maximumTokens: resourceBudget.scenarioImport.maximumTokens
            )
            var work = RouterJSONWorkBudget(limits: .init(
                maximumWorkUnits: resourceBudget.maximumJSONWorkUnits ?? derived.maximumWorkUnits,
                maximumKeyDecodes: resourceBudget.maximumJSONKeyDecodes ?? derived.maximumKeyDecodes
            ))
            try work.charge(1)
            try validateTransportStructure(resourceBudget: resourceBudget)
            let encoder = RouterTransientDescriptorTransport.encoder()
            encoder.outputFormatting = outputFormatting
            let data = try encoder.encode(self)
            try RouterScenarioImportPreflight.validate(
                data,
                maximumBytes: resourceBudget.scenarioImport.maximumEncodedBytes,
                maximumSteps: resourceBudget.maximumScenarioSteps,
                maximumDepth: resourceBudget.scenarioImport.maximumDepth,
                maximumTokens: resourceBudget.scenarioImport.maximumTokens,
                maximumWorkUnits: resourceBudget.maximumJSONWorkUnits,
                maximumKeyDecodes: resourceBudget.maximumJSONKeyDecodes,
                consumedWork: work.result
            )
            return data
        } catch let failure as RouterResourceLimitFailure {
            throw RouterScenarioFixtureError.resourceLimit(failure)
        } catch let failure as RouterJSONPreflightError {
            switch failure {
            case .limitExceeded(let name, let actual, let maximum):
                throw RouterScenarioFixtureError.resourceLimit(.init(resource: name, actual: actual, maximum: maximum))
            default: throw RouterScenarioFixtureError.malformedFixtureEnvelope
            }
        }
    }
}

extension RouterScenarioFixture {
    /// Used first on opaque, bounded import shape, and on every complete source
    /// value before export. Replaying a descriptor does not create a waiter.
    func validateTransportStructure(resourceBudget: RouterResourceBudget? = nil) throws {
        func state(_ value: RouterState<R>) throws {
            try resourceBudget?.validate(value)
            try value.validate()
        }
        func node(_ value: RouterNode<R>) throws {
            try resourceBudget?.validate(root: value)
            _ = try RouterState(root: value)
        }
        func action(_ input: RouterAction<R>) throws {
            try resourceBudget?.validateInput(input)
            var value = input
            while true {
                switch value {
                case .scoped(_, let child), .presentationScoped(_, let child),
                     .windowScoped(_, let child), .immersiveSpaceScoped(_, let child):
                    value = child
                case .apply(let plan): try state(plan.state); return
                case .present(let presentation): try node(.stack(presentation: presentation)); return
                case .presentAlert(let descriptor), .presentConfirmationDialog(let descriptor):
                    try descriptor.content.validate(); return
                case .openWindow(let window):
                    _ = try RouterState(windows: [window]); return
                case .enterImmersiveSpace(let space):
                    _ = try RouterState(immersiveSpace: space); return
                default: return
                }
            }
        }
        try state(initialState)
        for step in steps {
            try state(step.observedState)
            if let expectation = step.expectation { try state(expectation.state) }
            try action(step.action)
            switch step.requestSemantics {
            case .historyNavigation(let value): try state(value)
            case .featurePlan(let scope, _, let value, _):
                try resourceBudget?.validateReplacement(value, at: scope)
                try node(value)
            case .action, .featureAction: break
            }
        }
    }
}
