import InnoRouterCore

/// Stable, payload-free reason why a captured request cannot be replayed.
/// Runtime ownership tokens and callback closures are never serialized.
/// Unknown future codes round-trip and fail closed just like known codes.
public struct RouterScenarioReplayLimitation: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let runtimeOwnershipReplacement = Self(rawValue: "runtime.ownershipReplacement")
    public static let runtimeExecutionPrecondition = Self(rawValue: "runtime.executionPrecondition")
    public static let runtimeResultAuthority = Self(rawValue: "presentation.runtimeResultAuthority")
    public static let runtimeAuthorization = Self(rawValue: "runtime.authorization")

    static func validate<R: Route & Codable>(_ steps: [RouterScenarioStep<R>]) throws {
        for (index, step) in steps.enumerated() {
            if let code = step.replayLimitation {
                throw RouterScenarioReplayError.unsupportedRequestSemantics(step: index, code: code)
            }
        }
    }
}
