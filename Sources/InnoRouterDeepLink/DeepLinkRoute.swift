import Foundation

import InnoRouterCore

/// A route type that can resolve an admitted URL into one typed destination.
///
/// `DeepLinkRoute` is the small runtime capability used by macro-first hosts.
/// Implementations must fail closed by returning `nil` when the URL origin or
/// path is not explicitly supported. Use ``RouterLinkPipeline`` when a URL
/// needs authentication, pending replay, or a complete multi-branch plan; this
/// protocol intentionally resolves only one route value.
///
/// The resolver is synchronous and carries no session authority, so conforming
/// route enums remain immutable `Sendable` values.
public protocol DeepLinkRoute: Route {
    /// Compile-time route schema generated from `@Router` declarations.
    static var deepLinkCatalog: DeepLinkRouteCatalog { get }

    /// Returns the payload-free catalog case name for a resolved value.
    static func deepLinkCatalogCaseName(for route: Self) -> String?

    /// Type-erased form used when a parent router composes a feature route.
    func deepLinkCatalogCaseNameValue() -> String?

    /// Whether read-only explanation may invoke this pure resolver.
    static var supportsPureDeepLinkExplanation: Bool { get }

    /// Resolves `url` into one route, or returns `nil` when it is rejected or
    /// does not match this route type.
    static func resolveDeepLink(_ url: URL) -> Self?

    /// Renders this route into a canonical URL for `origin`, or returns `nil`
    /// when the route or origin is not representable by this route type.
    func deepLinkURL(origin: DeepLinkOrigin) -> URL?
}

public extension DeepLinkRoute {
    static var deepLinkCatalog: DeepLinkRouteCatalog {
        .init(schemes: [], hosts: [], entries: [])
    }

    static func deepLinkCatalogCaseName(for route: Self) -> String? {
        _ = route
        return nil
    }

    func deepLinkCatalogCaseNameValue() -> String? {
        Self.deepLinkCatalogCaseName(for: self)
    }

    static var supportsPureDeepLinkExplanation: Bool { false }

    /// Explains origin rejection, pattern selection, and conversion failure
    /// without exposing route payload values.
    static func explainDeepLink(
        _ url: URL,
        inputLimits: DeepLinkInputLimits = .default
    ) -> DeepLinkResolutionExplanation {
        return deepLinkCatalog.explain(
            url,
            inputLimits: inputLimits,
            shouldResolve: supportsPureDeepLinkExplanation
                && deepLinkCatalog.supportsPureResolution(of: url, inputLimits: inputLimits),
            resolve: resolveDeepLink,
            resolvedCaseName: deepLinkCatalogCaseName
        )
    }

    /// Preserves source compatibility for hand-written resolvers. Macro-backed
    /// routers override this default with a generated bidirectional mapping.
    func deepLinkURL(origin: DeepLinkOrigin) -> URL? {
        _ = origin
        return nil
    }
}

/// The route types already being walked by the current deep-link operation.
///
/// A feature graph may legitimately reach the same child type from different
/// parents, so the guard tracks the *current path* rather than every type ever
/// visited: a sibling that shares a child still contributes its entries. Each
/// operation kind carries its own path, so a catalog walk never suppresses a
/// resolution.
enum DeepLinkTraversal {
    enum Operation: Hashable, Sendable {
        case catalog
        case purity
        case resolve
        case caseName
        case url
    }

    struct Step: Hashable, Sendable {
        let type: ObjectIdentifier
        let operation: Operation
    }

    @TaskLocal static var path: Set<Step> = []

    /// Runs `body` with `step` on the path, or returns `cycle()` when the step
    /// is already there.
    ///
    /// The generated contracts are synchronous, so one call of an entry point
    /// is one traversal; nothing leaks between separate or nested calls.
    static func walking<Value>(
        _ type: Any.Type,
        _ operation: Operation,
        cycle: () -> Value,
        body: () -> Value
    ) -> Value {
        let step = Step(type: ObjectIdentifier(type), operation: operation)
        guard !path.contains(step) else { return cycle() }
        return $path.withValue(path.union([step]), operation: body)
    }
}

/// Type-erased bridge used by macro-generated parent routers to compose child
/// feature deep-link contracts without requiring the child module to know its
/// parent type.
///
/// A feature case may name its own route type, directly or through another
/// module, so every entry point below is re-entrant by construction. Each one
/// therefore refuses to walk a route type that is already on the current path
/// and fails closed for that edge: an empty catalog, an impure explanation, or
/// no resolution. Independent branches keep working.
public enum DeepLinkFeatureRuntime {
    public static func catalog<Child: Route>(for type: Child.Type) -> DeepLinkRouteCatalog {
        guard let routeType = type as? any DeepLinkRoute.Type else {
            return .init(schemes: [], hosts: [], entries: [])
        }
        return DeepLinkTraversal.walking(
            routeType,
            .catalog,
            cycle: { .init(schemes: [], hosts: [], entries: []) },
            body: { routeType.deepLinkCatalog }
        )
    }

    public static func supportsPureExplanation<Child: Route>(for type: Child.Type) -> Bool {
        guard let routeType = type as? any DeepLinkRoute.Type else { return false }
        return DeepLinkTraversal.walking(
            routeType,
            .purity,
            cycle: { false },
            body: { routeType.supportsPureDeepLinkExplanation }
        )
    }

    public static func resolve<Child: Route>(_ type: Child.Type, url: URL) -> Child? {
        guard let routeType = type as? any DeepLinkRoute.Type else { return nil }
        return DeepLinkTraversal.walking(
            routeType,
            .resolve,
            cycle: { nil },
            body: { routeType.resolveDeepLink(url) as? Child }
        )
    }

    public static func caseName<Child: Route>(for route: Child) -> String? {
        guard let route = route as? any DeepLinkRoute else { return nil }
        return DeepLinkTraversal.walking(
            type(of: route),
            .caseName,
            cycle: { nil },
            body: { route.deepLinkCatalogCaseNameValue() }
        )
    }

    public static func url<Child: Route>(
        for route: Child,
        origin: DeepLinkOrigin
    ) -> URL? {
        guard let route = route as? any DeepLinkRoute else { return nil }
        return DeepLinkTraversal.walking(
            type(of: route),
            .url,
            cycle: { nil },
            body: { route.deepLinkURL(origin: origin) }
        )
    }
}
