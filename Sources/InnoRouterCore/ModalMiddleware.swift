/// A middleware that can observe, transform, or cancel `ModalCommand`
/// executions before and after they touch `ModalStore` state.
///
/// `ModalMiddleware` mirrors `NavigationMiddleware`. Unlike navigation, modal
/// commands do not have a per-command result type; `didExecute` therefore
/// returns `Void`. Analytics that need a signal should use the telemetry
/// surface (`ModalStoreConfiguration.onEvent`).
@MainActor
public protocol ModalMiddleware {
    associatedtype RouteType: Route

    /// Called before `command` is applied to the store. Return `.proceed(command)`
    /// to accept (or rewrite) the command, or `.cancel(reason)` to drop it.
    ///
    /// - Parameters:
    ///   - command: Command about to execute.
    ///   - currentPresentation: The currently active modal, if any.
    ///   - queuedPresentations: Modals currently waiting behind the active one.
    func willExecute(
        _ command: ModalCommand<RouteType>,
        currentPresentation: ModalPresentation<RouteType>?,
        queuedPresentations: [ModalPresentation<RouteType>]
    ) -> ModalInterception<RouteType>

    /// Called after `command` mutates the store state. Runs only for
    /// middlewares whose `willExecute` returned `.proceed` for the same
    /// command (participant discipline mirrors `NavigationMiddleware`).
    func didExecute(
        _ command: ModalCommand<RouteType>,
        currentPresentation: ModalPresentation<RouteType>?,
        queuedPresentations: [ModalPresentation<RouteType>]
    )
}

/// Closure-based type-erased modal middleware.
@MainActor
public struct AnyModalMiddleware<M: Route>: ModalMiddleware, Sendable {
    public typealias RouteType = M

    private let _willExecute: @MainActor @Sendable (
        ModalCommand<M>,
        ModalPresentation<M>?,
        [ModalPresentation<M>]
    ) -> ModalInterception<M>
    private let _didExecute: @MainActor @Sendable (
        ModalCommand<M>,
        ModalPresentation<M>?,
        [ModalPresentation<M>]
    ) -> Void

    /// Wraps a concrete `ModalMiddleware`.
    public init<Wrapped: ModalMiddleware>(_ middleware: Wrapped) where Wrapped.RouteType == M {
        self._willExecute = { command, current, queue in
            middleware.willExecute(
                command,
                currentPresentation: current,
                queuedPresentations: queue
            )
        }
        self._didExecute = { command, current, queue in
            middleware.didExecute(
                command,
                currentPresentation: current,
                queuedPresentations: queue
            )
        }
    }

    /// Composes middleware from closures.
    public init(
        willExecute: @escaping @MainActor @Sendable (
            ModalCommand<M>,
            ModalPresentation<M>?,
            [ModalPresentation<M>]
        ) -> ModalInterception<M>,
        didExecute: @escaping @MainActor @Sendable (
            ModalCommand<M>,
            ModalPresentation<M>?,
            [ModalPresentation<M>]
        ) -> Void = { _, _, _ in }
    ) {
        self._willExecute = willExecute
        self._didExecute = didExecute
    }

    public func willExecute(
        _ command: ModalCommand<M>,
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) -> ModalInterception<M> {
        _willExecute(command, currentPresentation, queuedPresentations)
    }

    public func didExecute(
        _ command: ModalCommand<M>,
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) {
        _didExecute(command, currentPresentation, queuedPresentations)
    }
}
