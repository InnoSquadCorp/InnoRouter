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

`.whenCancelled(primary, fallback:)` is also command algebra.

That means:

- `primary` runs first
- if `primary` reports anything other than success, the store restores the snapshot and runs `fallback`
- both legs still pass through middleware recursively
- single-command execution only emits the committed state change
- transaction execution keeps public middleware observation commit-only, while discarded preview legs run internal cleanup

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
