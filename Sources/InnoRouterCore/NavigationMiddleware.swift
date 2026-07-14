@MainActor
public protocol NavigationMiddleware<RouteType> {
    associatedtype RouteType: Route

    func willExecute(_ command: NavigationCommand<RouteType>, state: RouteStack<RouteType>) -> NavigationInterception<RouteType>
    func didExecute(
        _ command: NavigationCommand<RouteType>,
        result: NavigationResult<RouteType>,
        state: RouteStack<RouteType>
    ) -> NavigationResult<RouteType>
}

@MainActor
package protocol NavigationMiddlewareDiscardCleanup<RouteType> {
    associatedtype RouteType: Route

    func discardExecution(
        _ command: NavigationCommand<RouteType>,
        result: NavigationResult<RouteType>,
        state: RouteStack<RouteType>
    )
}

@MainActor
public struct AnyNavigationMiddleware<R: Route>: NavigationMiddleware, Sendable {
    public typealias RouteType = R

    private let _willExecute: @MainActor @Sendable (NavigationCommand<R>, RouteStack<R>) -> NavigationInterception<R>
    private let _didExecute: @MainActor @Sendable (NavigationCommand<R>, NavigationResult<R>, RouteStack<R>) -> NavigationResult<R>
    private let _discardExecution: @MainActor @Sendable (NavigationCommand<R>, NavigationResult<R>, RouteStack<R>) -> Void

    public init<M: NavigationMiddleware>(_ middleware: M) where M.RouteType == R {
        self._willExecute = { command, state in middleware.willExecute(command, state: state) }
        self._didExecute = { command, result, state in middleware.didExecute(command, result: result, state: state) }
        // Constrained existential lookup (Swift 5.7+ primary
        // associated types) replaces the previous `Any`-boxed
        // protocol — the cleanup middleware now arrives with its
        // `RouteType` already pinned to `R`, so the cast cannot
        // silently bind to an unrelated route type.
        if let cleanupMiddleware = middleware as? any NavigationMiddlewareDiscardCleanup<R> {
            self._discardExecution = { command, result, state in
                cleanupMiddleware.discardExecution(command, result: result, state: state)
            }
        } else {
            self._discardExecution = { _, _, _ in }
        }
    }

    public init(
        willExecute: @escaping @MainActor @Sendable (NavigationCommand<R>, RouteStack<R>) -> NavigationInterception<R>,
        didExecute: @escaping @MainActor @Sendable (NavigationCommand<R>, NavigationResult<R>, RouteStack<R>) -> NavigationResult<R> = { _, result, _ in result }
    ) {
        self._willExecute = willExecute
        self._didExecute = didExecute
        self._discardExecution = { _, _, _ in }
    }

    public func willExecute(_ command: NavigationCommand<R>, state: RouteStack<R>) -> NavigationInterception<R> {
        _willExecute(command, state)
    }

    public func didExecute(
        _ command: NavigationCommand<R>,
        result: NavigationResult<R>,
        state: RouteStack<R>
    ) -> NavigationResult<R> {
        _didExecute(command, result, state)
    }

    package func discardExecution(
        _ command: NavigationCommand<R>,
        result: NavigationResult<R>,
        state: RouteStack<R>
    ) {
        _discardExecution(command, result, state)
    }
}
