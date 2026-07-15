import InnoRouterCore

/// Configuration for constructing a `FlowStore`.
///
/// A `FlowStore` owns an inner `NavigationStore` and `ModalStore`; this
/// configuration gives callers a single entry point for configuring both of
/// them (logging, middleware, and per-store observation) plus the FlowStore
/// specific unified observation hook.
///
/// Stored properties are `public var` so call sites can adjust
/// the observation hook after construction without re-stating every
/// other parameter — see ``NavigationStoreConfiguration`` for the
/// same pattern.
public struct FlowStoreConfiguration<R: Route>: Sendable {
    /// Configuration applied to the inner `NavigationStore`.
    public var navigation: NavigationStoreConfiguration<R>
    /// Configuration applied to the inner `ModalStore`.
    public var modal: ModalStoreConfiguration<R>
    /// Called synchronously for every public flow observation event.
    ///
    /// This includes flow-level path changes and intent rejections as well as
    /// ``FlowEvent/navigation(_:)`` and ``FlowEvent/modal(_:)`` wrappers for
    /// every event emitted by the inner stores.
    public var onEvent: (@MainActor @Sendable (FlowEvent<R>) -> Void)?
    /// Backpressure policy applied to each subscriber of ``FlowStore/events``.
    ///
    /// Controls the flow-level fan-out only; the inner `NavigationStore` and
    /// `ModalStore` carry their own policies through ``NavigationStoreConfiguration/eventBufferingPolicy``
    /// and ``ModalStoreConfiguration/eventBufferingPolicy``. Defaults to
    /// ``EventBufferingPolicy/default``.
    public var eventBufferingPolicy: EventBufferingPolicy

    /// Policy applied to ``ModalStore/queuedPresentations`` when a
    /// `NavigationStore` middleware cancels a flow-level command.
    ///
    /// Defaults to ``QueueCoalescePolicy/preserve`` so the pre-4.0
    /// observable behaviour is unchanged. Opt into
    /// ``QueueCoalescePolicy/dropQueued`` if a cancelled navigation
    /// prefix should also dismiss any modal that was waiting behind
    /// it, or supply a ``QueueCoalescePolicy/custom(_:)`` closure
    /// to decide per intent + rejection reason.
    public var queueCoalescePolicy: QueueCoalescePolicy<R>

    /// Creates a flow store configuration.
    public init(
        navigation: NavigationStoreConfiguration<R> = .init(),
        modal: ModalStoreConfiguration<R> = .init(),
        onEvent: (@MainActor @Sendable (FlowEvent<R>) -> Void)? = nil,
        eventBufferingPolicy: EventBufferingPolicy = .default,
        queueCoalescePolicy: QueueCoalescePolicy<R> = .preserve
    ) {
        self.navigation = navigation
        self.modal = modal
        self.onEvent = onEvent
        self.eventBufferingPolicy = eventBufferingPolicy
        self.queueCoalescePolicy = queueCoalescePolicy
    }
}
