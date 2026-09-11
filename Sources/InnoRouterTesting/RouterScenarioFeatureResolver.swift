import InnoRouterCore

/// A typed projection chain used to build a replay resolver from the same
/// macro-generated feature mappings used by production routing.
public struct RouterScenarioFeatureProjection<Root: Route, Feature: Route>: Sendable {
    package let features: [RouterFeatureCatalogEntry]

    package let project: @Sendable (RouterNode<Root>) throws -> RouterNode<Feature>

    public init(_ mapping: RouterFeatureMapping<Root, Feature>) {
        features = [Self.entry(for: mapping)]
        project = mapping.project
    }

    /// Extends this projection through one nested feature composition point.
    public func appending<Child: Route>(
        _ mapping: RouterFeatureMapping<Feature, Child>
    ) -> RouterScenarioFeatureProjection<Root, Child> {
        let upstream = project
        return .init(
            features: features + [Self.entry(for: mapping)],
            project: { try mapping.project(upstream($0)) }
        )
    }

    /// Erases the projected route type while retaining its ownership check.
    public func eraseToResolver() -> RouterScenarioFeatureResolver<Root> {
        .init(features: features) { node in
            (try? project(node)) != nil
        }
    }

    package init(
        features: [RouterFeatureCatalogEntry],
        project: @escaping @Sendable (RouterNode<Root>) throws -> RouterNode<Feature>
    ) {
        self.features = features
        self.project = project
    }

    private static func entry<Parent: Route, Child: Route>(
        for mapping: RouterFeatureMapping<Parent, Child>
    ) -> RouterFeatureCatalogEntry {
        .init(
            id: mapping.id,
            namespace: mapping.namespace,
            childRouteTypeName: String(describing: Child.self)
        )
    }
}

/// Type-erased ownership validation for one serialized feature-plan path.
///
/// For a direct feature, initialize this value with the macro-generated
/// `Parent.Feature.child` mapping. For nested features, build a
/// ``RouterScenarioFeatureProjection`` chain and erase it.
public struct RouterScenarioFeatureResolver<Root: Route>: Sendable {
    package let features: [RouterFeatureCatalogEntry]

    package let owns: @Sendable (RouterNode<Root>) -> Bool

    public init<Feature: Route>(_ mapping: RouterFeatureMapping<Root, Feature>) {
        self = RouterScenarioFeatureProjection(mapping).eraseToResolver()
    }

    package init(
        features: [RouterFeatureCatalogEntry],
        owns: @escaping @Sendable (RouterNode<Root>) -> Bool
    ) {
        self.features = features
        self.owns = owns
    }
}

package struct RouterScenarioFeatureResolverRegistry<R: Route>: Sendable {
    private let resolvers: [[RouterFeatureCatalogEntry]: RouterScenarioFeatureResolver<R>]

    init(_ values: [RouterScenarioFeatureResolver<R>]) throws {
        var resolvers: [[RouterFeatureCatalogEntry]: RouterScenarioFeatureResolver<R>] = [:]
        for value in values {
            guard resolvers.updateValue(value, forKey: value.features) == nil else {
                throw RouterScenarioReplayError.duplicateFeatureResolver(
                    namespaces: value.features.map(\.namespace)
                )
            }
        }
        self.resolvers = resolvers
    }

    func require(_ features: [RouterFeatureCatalogEntry]) throws {
        guard resolvers[features] != nil else {
            throw RouterScenarioReplayError.missingFeatureResolver(
                namespaces: features.map(\.namespace)
            )
        }
    }

    func owns(
        _ node: RouterNode<R>,
        features: [RouterFeatureCatalogEntry]
    ) -> Bool {
        resolvers[features]?.owns(node) == true
    }
}
