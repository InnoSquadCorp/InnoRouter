import Foundation
import Synchronization

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

package struct DeepLinkTraversalLimits: Sendable, Hashable {
    package let maximumDepth: Int
    package let maximumEntryAttempts: Int

    package init(maximumDepth: Int, maximumEntryAttempts: Int) {
        precondition(maximumDepth > 0)
        precondition(maximumEntryAttempts > 0)
        self.maximumDepth = maximumDepth
        self.maximumEntryAttempts = maximumEntryAttempts
    }

    package static let production = Self(maximumDepth: 64, maximumEntryAttempts: 1_024)
}

/// Package-only deterministic boundary control. Production callers always use
/// ``DeepLinkTraversalLimits/production``.
package enum DeepLinkTraversalTestSupport {
    @TaskLocal package static var limits = DeepLinkTraversalLimits.production

    package static func withLimits<Value>(
        _ limits: DeepLinkTraversalLimits,
        operation: () throws -> Value
    ) rethrows -> Value {
        try $limits.withValue(limits, operation: operation)
    }
}

/// One bounded, synchronous feature-graph traversal.
private enum DeepLinkTraversal {
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

    enum Entry {
        case entered
        case cycle
        case limitExceeded
    }

    final class Context: Sendable {
        private struct State {
            var path: [Step] = []
            var active: Set<Step> = []
            var entryAttempts = 0
            var didExceedLimit = false
        }

        private let state = Mutex(State())
        private let limits: DeepLinkTraversalLimits

        init(limits: DeepLinkTraversalLimits = DeepLinkTraversalTestSupport.limits) {
            self.limits = limits
        }

        var didExceedLimit: Bool {
            state.withLock { $0.didExceedLimit }
        }

        func enter(_ step: Step) -> Entry {
            state.withLock { state in
                guard !state.didExceedLimit else { return .limitExceeded }
                state.entryAttempts += 1
                guard state.entryAttempts <= limits.maximumEntryAttempts else {
                    state.didExceedLimit = true
                    return .limitExceeded
                }
                guard !state.active.contains(step) else { return .cycle }
                guard state.path.count < limits.maximumDepth else {
                    state.didExceedLimit = true
                    return .limitExceeded
                }
                _ = state.active.insert(step)
                state.path.append(step)
                return .entered
            }
        }

        func leave(_ step: Step) {
            state.withLock { state in
                precondition(state.path.last == step, "Unbalanced deep-link traversal")
                state.path.removeLast()
                state.active.remove(step)
            }
        }
    }

    @TaskLocal static var context: Context?
    @TaskLocal static var authorizedGeneratedEntry: Step?

    static func root<Value>(
        _ type: Any.Type,
        _ operation: Operation,
        limit: (Value) -> Value,
        body: () -> Value
    ) -> Value {
        let step = Step(type: ObjectIdentifier(type), operation: operation)
        if context != nil, authorizedGeneratedEntry == step {
            // The feature bridge already admitted this generated child entry.
            return body()
        }

        // A direct or genuinely nested public entry starts an independent
        // traversal. Only bridge-dispatched child entries share their parent.
        let context = Context()
        return $context.withValue(context) {
            guard case .entered = context.enter(step) else {
                preconditionFailure("A fresh deep-link traversal could not enter its root")
            }
            defer { context.leave(step) }
            let value = body()
            return context.didExceedLimit ? limit(value) : value
        }
    }

    static func feature<Value>(
        _ type: Any.Type,
        _ operation: Operation,
        cycle: () -> Value,
        limit: () -> Value,
        body: () -> Value
    ) -> Value {
        let step = Step(type: ObjectIdentifier(type), operation: operation)
        if let context {
            return feature(
                step,
                in: context,
                cycle: cycle,
                limit: limit,
                body: body
            )
        }
        let context = Context()
        return $context.withValue(context) {
            feature(
                step,
                in: context,
                cycle: cycle,
                limit: limit,
                body: body
            )
        }
    }

    private static func feature<Value>(
        _ step: Step,
        in context: Context,
        cycle: () -> Value,
        limit: () -> Value,
        body: () -> Value
    ) -> Value {
        switch context.enter(step) {
        case .cycle:
            return cycle()
        case .limitExceeded:
            return limit()
        case .entered:
            defer { context.leave(step) }
            let value = $authorizedGeneratedEntry.withValue(step, operation: body)
            return context.didExceedLimit ? limit() : value
        }
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
    public static func catalog<Child: Route>(
        for type: Child.Type,
        body: (() -> DeepLinkRouteCatalog)? = nil
    ) -> DeepLinkRouteCatalog {
        if let body {
            return DeepLinkTraversal.root(type, .catalog, limit: { catalog in
                .init(
                    schemes: catalog.schemes,
                    hosts: catalog.hosts,
                    entries: [],
                    isComplete: false
                )
            }, body: body)
        }
        guard let routeType = type as? any DeepLinkRoute.Type else {
            return .init(schemes: [], hosts: [], entries: [])
        }
        return DeepLinkTraversal.feature(
            type,
            .catalog,
            cycle: { .init(schemes: [], hosts: [], entries: []) },
            limit: { .init(schemes: [], hosts: [], entries: [], isComplete: false) },
            body: { routeType.deepLinkCatalog }
        )
    }

    public static func supportsPureExplanation<Child: Route>(
        for type: Child.Type,
        body: (() -> Bool)? = nil
    ) -> Bool {
        if let body {
            return DeepLinkTraversal.root(type, .purity, limit: { _ in false }, body: body)
        }
        guard let routeType = type as? any DeepLinkRoute.Type else { return false }
        return DeepLinkTraversal.feature(
            type,
            .purity,
            cycle: { false },
            limit: { false },
            body: { routeType.supportsPureDeepLinkExplanation }
        )
    }

    public static func resolve<Child: Route>(
        _ type: Child.Type,
        url: URL,
        body: (() -> Child?)? = nil
    ) -> Child? {
        if let body {
            return DeepLinkTraversal.root(type, .resolve, limit: { _ in nil }, body: body)
        }
        guard let routeType = type as? any DeepLinkRoute.Type else { return nil }
        return DeepLinkTraversal.feature(
            type,
            .resolve,
            cycle: { nil },
            limit: { nil },
            body: { routeType.resolveDeepLink(url) as? Child }
        )
    }

    public static func caseName<Child: Route>(
        for route: Child,
        body: (() -> String?)? = nil
    ) -> String? {
        if let body {
            return DeepLinkTraversal.root(Child.self, .caseName, limit: { _ in nil }, body: body)
        }
        guard let route = route as? any DeepLinkRoute else { return nil }
        return DeepLinkTraversal.feature(
            Child.self,
            .caseName,
            cycle: { nil },
            limit: { nil },
            body: { route.deepLinkCatalogCaseNameValue() }
        )
    }

    public static func url<Child: Route>(
        for route: Child,
        origin: DeepLinkOrigin,
        body: (() -> URL?)? = nil
    ) -> URL? {
        if let body {
            return DeepLinkTraversal.root(Child.self, .url, limit: { _ in nil }, body: body)
        }
        guard let route = route as? any DeepLinkRoute else { return nil }
        return DeepLinkTraversal.feature(
            Child.self,
            .url,
            cycle: { nil },
            limit: { nil },
            body: { route.deepLinkURL(origin: origin) }
        )
    }
}
