# `QueueCoalescePolicy` — handling cancelled commands with a live modal queue

`FlowStore` lets a `NavigationStore` middleware cancel a
flow-level command (`.replaceStack`, `.reset`, `.backOrPush…`)
even when a modal queue is already active. The default behaviour
preserves the queue across the cancellation; opt into a stricter
policy with `FlowStoreConfiguration.queueCoalescePolicy`.

## When the policy engages

The policy only engages when navigation middleware **cancels** a
flow-level command — i.e. the rejection reason surfaced to
`FlowStoreConfiguration.onEvent` as
`.intentRejected(_, .middlewareRejected)`.
Caller-side invariant rejections (`.pushBlockedByModalTail`,
`.invalidResetPath`) ignore the policy because they signal a
caller bug, not an entitlement / analytics gate.

`.push` is the most common command engineers reach for, but
FlowStore rejects `.push` with `.pushBlockedByModalTail` before
the request reaches navigation middleware whenever a modal tail
is active. The policy never fires for cancelled `.push`
commands. The realistic vector is `.replaceStack(_:)`, which is
legal while a modal tail is active (the reset dismisses the
modal as part of its semantics) and therefore reaches
middleware.

## The three policies

| Policy | Effect on the modal queue |
|---|---|
| `.preserve` | Queue and active modal stay exactly as they were before the cancelled command. **Default.** |
| `.dropQueued` | Active modal dismisses and every queued presentation drops, equivalent to `modalStore.dismissAll`. |
| `.custom { intent, reason in … }` | Closure decides per call; returns `.preserve` or `.dropQueued`. |

## Picking one

- **Most apps stay on `.preserve`.** A queued sheet that survives
  a cancelled navigation prefix is usually the right user
  experience — the user dismisses the modal explicitly when
  they're done with it, regardless of what the navigation layer
  decided.
- **Wizard / onboarding flows** that drive `.replaceStack` from
  a single source of truth often want `.dropQueued`. If the
  reset is cancelled, the queued sheet is conceptually part of
  the same intent and shouldn't outlive it.
- **Custom analytics pipelines** can use `.custom(_:)` to
  inspect the cancelled intent + rejection reason and feed that
  decision back to telemetry without writing extra middleware.

```swift skip doc-fragment
let config = FlowStoreConfiguration<AppRoute>(
    queueCoalescePolicy: .custom { intent, reason in
        analytics.recordCancellation(intent: intent, reason: reason)
        if case .replaceStack = intent {
            return .dropQueued
        }
        return .preserve
    }
)
```
