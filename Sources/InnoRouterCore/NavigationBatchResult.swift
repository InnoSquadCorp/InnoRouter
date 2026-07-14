public struct NavigationBatchResult<R: Route>: Sendable, Equatable {
    /// Commands originally requested for batch execution.
    public let requestedCommands: [NavigationCommand<R>]
    /// Commands actually executed after middleware interception and rewriting.
    public let executedCommands: [NavigationCommand<R>]
    /// Per-step execution results in the same order as the requested commands.
    public let results: [NavigationResult<R>]
    /// Navigation state before the batch started.
    public let stateBefore: RouteStack<R>
    /// Navigation state after the batch completed.
    public let stateAfter: RouteStack<R>
    /// Indicates whether execution stopped early because `stopOnFailure` was enabled.
    public let hasStoppedOnFailure: Bool

    /// `true` when the batch executed at least one command and every
    /// per-step result succeeded. An empty batch is *not* a success —
    /// mirroring `NavigationResult.multiple([])` — because requesting
    /// zero commands is treated as a programming error rather than a
    /// vacuous success.
    public var isSuccess: Bool {
        !results.isEmpty && results.allSatisfy(\.isSuccess)
    }

    /// Creates a batch execution result.
    public init(
        requestedCommands: [NavigationCommand<R>],
        executedCommands: [NavigationCommand<R>],
        results: [NavigationResult<R>],
        stateBefore: RouteStack<R>,
        stateAfter: RouteStack<R>,
        hasStoppedOnFailure: Bool
    ) {
        self.requestedCommands = requestedCommands
        self.executedCommands = executedCommands
        self.results = results
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
        self.hasStoppedOnFailure = hasStoppedOnFailure
    }
}
