# Command, batch, and transaction semantics

@Metadata {
  @PageKind(article)
}

InnoRouter exposes three different execution semantics on purpose.

## Single-command execution

`NavigationCommand` models one navigation transition or a recursive command composition.

Important cases:

- `.push`
- `.pushAll`
- `.pop`
- `.popCount`
- `.popToRoot`
- `.popTo`
- `.replace`
- `.sequence`
- `.whenCancelled`

`NavigationEngine` executes these commands against a `RouteStack`.

## Sequence semantics

`.sequence` is command algebra, not a transaction.

That means:

- commands execute left-to-right
- earlier successful steps stay applied even if a later step fails
- later steps still run unless the sequence itself has no more elements
- the final result is `NavigationResult.multiple(_:)`

Use `.sequence` when partial success is acceptable and the command stream itself is the point.

## Fallback semantics

`.whenCancelled(primary, fallback:)` is choice composition with an internal
savepoint.

That means:

- `primary` runs first against a shadow copy of the starting state
- if `primary` succeeds, only its final state commits
- if `primary` reports anything other than success, its shadow is discarded and `fallback` starts from the same snapshot
- if `fallback` succeeds, only its final state commits
- if both legs fail, both shadows are discarded, the starting `RouteStack` remains unchanged, and the fallback failure is returned
- `NavigationStore` routes each attempted leg recursively through middleware; direct `NavigationEngine` execution has no middleware
- single-command execution only emits the successful leg's committed state change
- transaction execution keeps public middleware observation commit-only, while discarded preview legs run internal cleanup

For direct and batch store execution, the folded `didExecute` result decides
whether a leg succeeded. Transaction execution must choose and commit from its
preview result so `didExecute` stays commit-only; a post-commit fold changes the
reported result but cannot reopen fallback selection or undo the commit.

`executedCommands` is an attempt log, not a commit log. It records effective
commands passed to the engine, including attempts later discarded by either
savepoint or transaction rollback; middleware interceptions cancelled before
the engine are not included. The savepoint protects `RouteStack` authority, not
arbitrary side effects performed by attempt-level middleware callbacks.

Use `.whenCancelled` when rollback-to-fallback semantics belong to one logical command.

## Batch semantics

`NavigationBatchExecutor.executeBatch(_:stopOnFailure:)` is for observation batching.

Batch execution still runs commands one step at a time, but it lets higher layers coalesce observation:

- step middleware still runs
- `stopOnFailure: false` keeps later commands running after a failure
- `stopOnFailure: true` stops the batch after the first failed step
- the store emits aggregated `.changed` and `.batchExecuted` cases
  through `onEvent` and `events`
- the caller gets a structured `NavigationBatchResult`

Use batch execution when the caller wants one “transition event” while still preserving per-step execution.

## Transaction semantics

`NavigationTransactionExecutor.executeTransaction(_:)` is the atomic option.

Transactions:

- reject an empty command list as uncommitted, with no failure index because no step ran
- preview commands on a shadow stack
- abort on the first failure or cancellation
- leave the real state unchanged on failure
- commit the final state all at once on success
- surface public `didExecute` / transaction observation only for committed leaves
- run internal discard cleanup for previewed leaves that never commit

Use transactions when all-or-nothing semantics are required.

## Typed failures

Core legality failures stay in typed results instead of exceptions:

- `NavigationResult.emptyStack`
- `NavigationResult.invalidPopCount(_:)`
- `NavigationResult.insufficientStackDepth(requested:available:)`
- `NavigationResult.routeNotFound(_:)`
- `NavigationResult.cancelled(_:)`

This keeps navigation failure in normal control flow and makes policy handling easy to pattern-match.
