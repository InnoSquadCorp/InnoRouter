import InnoRouterCore

/// Public observation payload delivered whenever the middleware registry mutates.
///
/// `NavigationStore` already emits internal telemetry for every successful
/// middleware mutator (`add`, `insert`, `remove`, `replace`, `move`). This type
/// exposes the same signal through a public configuration hook so apps can feed
/// analytics pipelines without reaching for `@testable import`.
///
/// Invalid mutations — for example, `replaceMiddleware(...)` with an unknown
/// handle — do **not** produce a `MiddlewareMutationEvent`; only successful
/// mutations are observable. Refer to `NavigationMiddlewareMetadata.handle`
/// for stable identity across the lifetime of a registered middleware.
public struct MiddlewareMutationEvent<R: Route>: Equatable, Sendable {
    /// Categorises the mutation that produced this event.
    public enum Action: String, Equatable, Sendable {
        case added
        case inserted
        case removed
        case replaced
        case moved
    }

    /// The mutation that produced this event.
    public let action: Action

    /// Metadata of the mutated middleware registration (stable handle + debug name).
    public let metadata: NavigationMiddlewareMetadata

    /// Index at which the mutation landed inside the registry, when known.
    ///
    /// - `added`: the new last index (`count - 1`).
    /// - `inserted`: the clamped insertion index.
    /// - `removed`: the former index of the removed entry.
    /// - `replaced`: the in-place index of the replaced entry.
    /// - `moved`: the clamped target index.
    public let index: Int?
}

/// Public observation payload delivered whenever the modal middleware registry
/// mutates.
///
/// `ModalStore` emits internal telemetry for every successful middleware
/// mutator (`add`, `insert`, `remove`, `replace`, `move`). This type exposes
/// the same signal through a public configuration hook so apps can feed
/// analytics pipelines without reaching for `@testable import`.
///
/// Invalid mutations — for example, `replaceMiddleware(...)` with an unknown
/// handle — do **not** produce a `ModalMiddlewareMutationEvent`; only
/// successful mutations are observable. Refer to `ModalMiddlewareMetadata.handle`
/// for stable identity across the lifetime of a registered middleware.
public struct ModalMiddlewareMutationEvent<M: Route>: Equatable, Sendable {
    /// Categorises the mutation that produced this event.
    public enum Action: String, Equatable, Sendable {
        case added
        case inserted
        case removed
        case replaced
        case moved
    }

    /// The mutation that produced this event.
    public let action: Action

    /// Metadata of the mutated middleware registration (stable handle + debug name).
    public let metadata: ModalMiddlewareMetadata

    /// Index at which the mutation landed inside the registry, when known.
    ///
    /// - `added`: the new last index (`count - 1`).
    /// - `inserted`: the clamped insertion index.
    /// - `removed`: the former index of the removed entry.
    /// - `replaced`: the in-place index of the replaced entry.
    /// - `moved`: the clamped target index.
    public let index: Int?
}
