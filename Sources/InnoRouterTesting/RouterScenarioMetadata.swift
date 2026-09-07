import Foundation

public struct RouterScenarioDependency: Hashable, Sendable, Codable {
    public let id: String
    public let version: String
    public let capabilities: Set<String>

    public init(id: String, version: String, capabilities: Set<String> = []) {
        self.id = id
        self.version = version
        self.capabilities = capabilities
    }
}

public enum RouterScenarioReplayCapability: String, Hashable, Sendable, Codable {
    case deterministicClock
    case deterministicTransitionIDs
    case applicationEffects
}

/// Serializable compatibility contract checked before replay submits a
/// production request. It intentionally contains identifiers only, never
/// closures, credentials, route payload copies, or service responses.
public struct RouterScenarioMetadata: Hashable, Sendable, Codable {
    public let routeSchemaID: String
    public let environmentID: String
    public let environmentVersion: String
    public let dependencies: [RouterScenarioDependency]
    public let requiredCapabilities: Set<RouterScenarioReplayCapability>
    public let externalEffectIDs: Set<String>

    public init(
        routeSchemaID: String,
        environmentID: String = "portable",
        environmentVersion: String = "1",
        dependencies: [RouterScenarioDependency] = [],
        requiredCapabilities: Set<RouterScenarioReplayCapability> = [],
        externalEffectIDs: Set<String> = []
    ) {
        self.routeSchemaID = routeSchemaID
        self.environmentID = environmentID
        self.environmentVersion = environmentVersion
        self.dependencies = dependencies.sorted { $0.id < $1.id }
        self.requiredCapabilities = requiredCapabilities
        self.externalEffectIDs = externalEffectIDs
    }
}

/// Application-declared capabilities available to one replay process.
public struct RouterScenarioReplayEnvironment: Hashable, Sendable {
    public let routeSchemaID: String
    public let environmentID: String
    public let environmentVersion: String
    public let dependencies: [RouterScenarioDependency]
    public let capabilities: Set<RouterScenarioReplayCapability>
    public let externalEffectIDs: Set<String>

    public init(
        routeSchemaID: String,
        environmentID: String = "portable",
        environmentVersion: String = "1",
        dependencies: [RouterScenarioDependency] = [],
        capabilities: Set<RouterScenarioReplayCapability> = [],
        externalEffectIDs: Set<String> = []
    ) {
        self.routeSchemaID = routeSchemaID
        self.environmentID = environmentID
        self.environmentVersion = environmentVersion
        self.dependencies = dependencies.sorted { $0.id < $1.id }
        self.capabilities = capabilities
        self.externalEffectIDs = externalEffectIDs
    }
}
