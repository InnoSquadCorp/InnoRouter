import OSLog

import InnoRouterCore

/// Registers middleware for `NavigationStore` initialization.
public struct NavigationMiddlewareRegistration<R: Route>: Sendable {
    /// Middleware instance to register.
    public let middleware: AnyNavigationMiddleware<R>
    /// Optional debug label used in telemetry and diagnostics.
    public let debugName: String?

    /// Creates a middleware registration.
    public init(
        middleware: AnyNavigationMiddleware<R>,
        debugName: String? = nil
    ) {
        self.middleware = middleware
        self.debugName = debugName
    }
}

/// Debug metadata for a registered navigation middleware.
public struct NavigationMiddlewareMetadata: Equatable, Sendable {
    /// Stable handle used for future mutation operations.
    public let handle: NavigationMiddlewareHandle
    /// Optional debug label associated with the middleware.
    public let debugName: String?
}

/// Configuration for constructing a `NavigationStore`.
///
/// All stored properties are `public var` so call sites can build a
/// configuration with the desired policies and middleware once and then
/// adjust the unified observation hook without re-stating every other
/// parameter:
///
/// ```swift
/// var config = NavigationStoreConfiguration<AppRoute>()
/// config.pathMismatchPolicy = .assertAndReplace
/// config.onEvent = { event in
///     analytics.send(event)
/// }
/// let store = NavigationStore(configuration: config)
/// ```
///
/// The struct stays `Sendable`; mutating an instance does not affect
/// any `NavigationStore` already constructed from a previous copy.
public struct NavigationStoreConfiguration<R: Route>: Sendable {
    /// Initial middleware registrations.
    public var middlewares: [NavigationMiddlewareRegistration<R>]
    /// Validator used for externally supplied route stack snapshots.
    public var routeStackValidator: RouteStackValidator<R>
    /// Policy used when a SwiftUI path update cannot be reconciled structurally.
    ///
    /// Defaults to ``NavigationPathMismatchPolicy/replace``, which treats the
    /// SwiftUI binding as the source of truth for non-prefix rewrites while
    /// still emitting ``NavigationEvent/pathMismatch(_:)`` through `onEvent`
    /// and ``NavigationStore/events``. Debug builds that
    /// want to catch every unexpected rewrite can opt into
    /// ``NavigationPathMismatchPolicy/assertAndReplace`` without changing the
    /// production default.
    public var pathMismatchPolicy: NavigationPathMismatchPolicy<R>
    /// Optional logger used for observation events and internal execution traces.
    public var logger: Logger?
    /// Called synchronously for every public navigation observation event.
    ///
    /// The callback receives stack changes, batch and transaction completions,
    /// successful middleware mutations, and policy-driven path mismatch
    /// resolutions through a single ``NavigationEvent`` value. Invalid
    /// middleware mutations and successful prefix-only path reductions do not
    /// emit events.
    public var onEvent: (@MainActor @Sendable (NavigationEvent<R>) -> Void)?
    /// Backpressure policy applied to each subscriber of ``NavigationStore/events``.
    ///
    /// Defaults to ``EventBufferingPolicy/default`` (``EventBufferingPolicy/bufferingNewest(_:)``
    /// with a 1024-event ceiling). Opt into ``EventBufferingPolicy/unbounded`` when a
    /// deterministic test harness needs every emitted event.
    public var eventBufferingPolicy: EventBufferingPolicy
    /// Creates a navigation store configuration.
    public init(
        middlewares: [NavigationMiddlewareRegistration<R>] = [],
        routeStackValidator: RouteStackValidator<R> = .permissive,
        pathMismatchPolicy: NavigationPathMismatchPolicy<R> = .replace,
        logger: Logger? = nil,
        onEvent: (@MainActor @Sendable (NavigationEvent<R>) -> Void)? = nil,
        eventBufferingPolicy: EventBufferingPolicy = .default
    ) {
        self.middlewares = middlewares
        self.routeStackValidator = routeStackValidator
        self.pathMismatchPolicy = pathMismatchPolicy
        self.logger = logger
        self.onEvent = onEvent
        self.eventBufferingPolicy = eventBufferingPolicy
    }
}
