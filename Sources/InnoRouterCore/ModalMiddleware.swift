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

    /// Finalizes a command attempt with the actual live modal state that
    /// remains after execution or cancellation.
    ///
    /// Direct execution and committed Flow execution call this for the exact
    /// prefix of middleware whose `willExecute` ran, including a middleware
    /// that cancelled the command. A successful preview later rolled back by
    /// an enclosing atomic Flow reset does not call `didExecute`; package-owned
    /// stateful middleware can use `ModalMiddlewareDiscardCleanup` for that
    /// internal cleanup path. This commit-only rule prevents a callback from
    /// reporting shadow state that never became live.
    func didExecute(
        _ command: ModalCommand<RouteType>,
        currentPresentation: ModalPresentation<RouteType>?,
        queuedPresentations: [ModalPresentation<RouteType>]
    )
}

/// Package-only lifecycle cleanup for modal attempts previewed by a larger
/// atomic transaction and then rolled back.
///
/// This mirrors `NavigationMiddlewareDiscardCleanup`: public middleware keeps
/// the compact `willExecute` / `didExecute` surface, while package-owned
/// stateful middleware can release reservations made during `willExecute`
/// without receiving a false `didExecute` for state that never committed.
@MainActor
package protocol ModalMiddlewareDiscardCleanup<RouteType> {
    associatedtype RouteType: Route

    func discardExecution(
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
    private let _discardExecution: @MainActor @Sendable (
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
        if let cleanupMiddleware = middleware as? any ModalMiddlewareDiscardCleanup<M> {
            self._discardExecution = { command, current, queue in
                cleanupMiddleware.discardExecution(
                    command,
                    currentPresentation: current,
                    queuedPresentations: queue
                )
            }
        } else {
            self._discardExecution = { _, _, _ in }
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
        self._discardExecution = { _, _, _ in }
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

    package func discardExecution(
        _ command: ModalCommand<M>,
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) {
        _discardExecution(command, currentPresentation, queuedPresentations)
    }
}
