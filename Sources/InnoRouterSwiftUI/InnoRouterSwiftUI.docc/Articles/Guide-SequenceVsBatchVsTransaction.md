# Choosing Between `.sequence`, `executeBatch`, and `executeTransaction`

Three ways to apply more than one navigation command in a row.
They are not interchangeable — pick the one whose contract matches
the call site.

## Decision matrix

| You want… | Reach for | Why |
|---|---|---|
| One observable change for multiple commands, best-effort | `NavigationStore.executeBatch(_:stopOnFailure:)` | Per-step results, one `.changed` plus one `.batchExecuted` observation, optional fail-fast |
| All-or-nothing atomic apply with rollback on failure | `NavigationStore.executeTransaction(_:)` | Shadow-state preview, journal-based discard, one `.transactionExecuted` observation |
| Express the composite as one *command* that the engine can validate, plan, or rebuild | `NavigationCommand.sequence([...])` | Pure value composition; flows through `NavigationEngine` as a single command unit |
| Schedule a single command after a quiet window | `DebouncingNavigator` | Async wrapping navigator, `Clock`-injectable |
| Rate-limit per key | `ThrottleNavigationMiddleware` | Synchronous interception, last-accept timestamp |

## Mental model

`.sequence` is a **value**. It is just another `NavigationCommand`
case, so it has the same semantics as any single command:
deep-link planners can produce it, middleware can match against
it, the engine evaluates it left-to-right and reports the
component results as `.multiple([...])`.

`executeBatch` is an **execution mode**. The store iterates the
commands, accepts partial success unless `stopOnFailure: true`,
and coalesces observation: the SwiftUI state stays correct after
each step but only one `.changed` event surfaces at the end, followed
by `.batchExecuted`, through both `onEvent` and `events`. Use it for
analytics-clean compound actions ("complete
checkout: replace stack + dismiss modal").

`executeTransaction` is an **atomicity mode**. The store applies
each command to a shadow stack, journals what middleware accepted
or rejected, and only commits if every step succeeds. On failure,
the journal walks back through the discarded acceptances so
middleware see consistent before/after states. Use it for
correctness-critical compound actions ("if any step rejects, the
user sees no half-applied state"). An empty command list is not a
transactional success: it returns an uncommitted result with no
failure index because no command ran.

`.whenCancelled` adds a smaller savepoint *inside one command*:
primary and fallback each start from the same local snapshot, and
only one successful leg can change the stack. It does not turn a
surrounding batch into a transaction; later batch commands still
follow the batch's continuation policy.

## Worked examples

### Compose a single command that drives a deep link plan

```swift skip doc-fragment
let plan = NavigationPlan<AppRoute>(commands: [
    .replace([.home]),
    .push(.detail(id))
])
// Pass the plan to a single .sequence — the engine evaluates each
// component and reports `.multiple([...])` results.
let result = store.execute(.sequence(plan.commands))
```

Use when the deep-link planner already represents the path as a
sequence of `NavigationCommand`s and you want the planner output
to flow through the same code path as a single command.

### Apply a checkout flow as one observable step

```swift skip doc-fragment
let batch = store.executeBatch([
    .replace([.home]),
    .push(.orderConfirmation),
], stopOnFailure: false)
// Exactly one `events` emission of `.batchExecuted(batch)`.
analytics.track(batch.events) // snapshot, no per-step amplification
```

Use when partial success is acceptable but every step must show
up in the same analytics event.

### KYC step requiring all-or-nothing

```swift skip doc-fragment
let transaction = store.executeTransaction([
    .replace([.kycRoot]),
    .push(.kycDocumentUpload),
    .push(.kycReview),
])
guard transaction.isCommitted else {
    // Stack is back to its pre-transaction state; show error.
    return
}
```

Use when leaving the user on a half-rolled-out screen would be
worse than showing a "please retry" message.

### Async debounce on a search field

```swift skip doc-fragment
let debouncing = DebouncingNavigator(
    wrapping: store,
    interval: .milliseconds(300)
)
// Each keystroke calls debouncedExecute; only the latest survives.
await debouncing.debouncedExecute(.replace([.searchResults(query: q)]))
```

Use when the user is generating commands faster than the
navigation surface should react.

## Anti-patterns

- **Wrapping `executeBatch` in another `executeBatch` to "compose"
  events.** Use `.sequence` inside one batch instead.
- **Calling `executeTransaction` for analytics-clean grouping.**
  The shadow-state cost is wasted; reach for `executeBatch`.
- **Driving a debounce window from a middleware.** Middleware
  cannot reliably re-dispatch the deferred command; that is what
  `DebouncingNavigator` exists for.

## See also

- `NavigationStore`
- `NavigationCommand`
- `ThrottleNavigationMiddleware`
- `DebouncingNavigator`
