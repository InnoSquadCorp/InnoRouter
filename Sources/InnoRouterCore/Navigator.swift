@MainActor
/// Reads the current navigation state for a route domain.
public protocol NavigationStateReader: AnyObject {
    /// Route type managed by the reader.
    associatedtype RouteType: Route
    /// The current route stack snapshot.
    var state: RouteStack<RouteType> { get }
}

@MainActor
/// Executes individual navigation commands.
public protocol NavigationCommandExecutor: AnyObject {
    /// Route type handled by the executor.
    associatedtype RouteType: Route

    /// Executes a single navigation command.
    @discardableResult
    func execute(_ command: NavigationCommand<RouteType>) -> NavigationResult<RouteType>
}

@MainActor
/// Executes multiple navigation commands as a batch.
public protocol NavigationBatchExecutor: AnyObject {
    /// Route type handled by the executor.
    associatedtype RouteType: Route

    @discardableResult
    /// Executes commands in order and optionally stops on the first failure.
    func executeBatch(
        _ commands: [NavigationCommand<RouteType>],
        stopOnFailure: Bool
    ) -> NavigationBatchResult<RouteType>
}

@MainActor
/// Executes multiple navigation commands transactionally.
public protocol NavigationTransactionExecutor: AnyObject {
    /// Route type handled by the executor.
    associatedtype RouteType: Route

    @discardableResult
    /// Executes a non-empty command list on a shadow stack and commits only
    /// when every step succeeds. An empty list returns an uncommitted result.
    func executeTransaction(
        _ commands: [NavigationCommand<RouteType>]
    ) -> NavigationTransactionResult<RouteType>
}

public typealias Navigator = NavigationStateReader & NavigationCommandExecutor
