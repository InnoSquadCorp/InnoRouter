import InnoRouterCore

/// Abstract interface for objects that own a `FlowStore` and dispatch
/// `FlowIntent` values through it.
///
/// `FlowNavigating` mirrors the convention established by `Coordinator`
/// (navigation), but targets `FlowStore`'s combined navigation and modal
/// authority. Consumers implement `flowStore` and optionally override
/// `handle(_:)`; the default implementation forwards to `flowStore.send(_:)`.
@MainActor
public protocol FlowNavigating: AnyObject {
    associatedtype RouteType: Route

    /// The flow store owned by this navigator.
    var flowStore: FlowStore<RouteType> { get }

    /// Handle a flow intent. Default implementation forwards to
    /// `flowStore.send(_:)`.
    func handle(_ intent: FlowIntent<RouteType>)
}

public extension FlowNavigating {
    func handle(_ intent: FlowIntent<RouteType>) {
        flowStore.send(intent)
    }
}
