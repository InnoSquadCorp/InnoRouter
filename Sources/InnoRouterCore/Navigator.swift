/// Reads the current navigation state for a route domain.
@MainActor
public protocol NavigationStateReader: AnyObject {
    /// Route type managed by the reader.
    associatedtype RouteType: Route
    /// The current route stack snapshot.
    var state: RouteStack<RouteType> { get }
}

/// Executes individual navigation commands.
@MainActor
public protocol NavigationCommandExecutor: AnyObject {
    /// Route type handled by the executor.
    associatedtype RouteType: Route

    /// Executes a single navigation command.
    @discardableResult
    func execute(_ command: NavigationCommand<RouteType>) -> NavigationResult<RouteType>
}

/// Executes multiple navigation commands as a batch.
@MainActor
public protocol NavigationBatchExecutor: AnyObject {
    /// Route type handled by the executor.
    associatedtype RouteType: Route

    /// Executes commands in order and optionally stops on the first failure.
    @discardableResult
    func executeBatch(
        _ commands: [NavigationCommand<RouteType>],
        stopOnFailure: Bool
    ) -> NavigationBatchResult<RouteType>
}

/// Executes multiple navigation commands transactionally.
@MainActor
public protocol NavigationTransactionExecutor: AnyObject {
    /// Route type handled by the executor.
    associatedtype RouteType: Route

    /// Executes a non-empty command list on a shadow stack and commits only
    /// when every step succeeds. An empty list returns an uncommitted result.
    @discardableResult
    func executeTransaction(
        _ commands: [NavigationCommand<RouteType>]
    ) -> NavigationTransactionResult<RouteType>
}

public typealias Navigator = NavigationStateReader & NavigationCommandExecutor
