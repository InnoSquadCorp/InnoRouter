# Event Stream Backpressure

@Metadata {
  @PageKind(article)
}

How the `events` stream of every store handles slow or stuck subscribers.

## Overview

Every `NavigationStore`, `ModalStore`, `FlowStore`, and `SceneStore`
publishes an `events: AsyncStream` that fans every observation event
out to every subscriber. The fan-out is implemented as a per-subscriber
`AsyncStream.Continuation`, which means a slow or cancelled subscriber
that never drains its stream would otherwise retain every event
indefinitely — behaving as an unbounded leak when the broadcaster
outlives all consumers.

To bound that growth, every store uses an `EventBufferingPolicy`.
`NavigationStore`, `ModalStore`, and `FlowStore` expose the policy through
their configurations. `SceneStore` currently uses the default policy.

Each access to a store's `events` property creates and synchronously registers
a new subscriber. Capture that stream before starting its lifecycle-owned task;
otherwise a route mutation performed immediately after task creation can occur
before the task first evaluates `store.events`. Request a fresh stream for each
independent consumer.

## Default policy

The default is `EventBufferingPolicy.default`, which is
`.bufferingNewest(1024)`. The number is sized for realistic navigation
bursts (a few hundred events for the longest deep-link replay we have
measured) while keeping the retained working set bounded so a stuck
subscriber cannot balloon memory in production.

## Choosing a policy

| Policy | Behaviour | When to use |
|---|---|---|
| `.bufferingNewest(N)` | Retain at most `N` most-recently-broadcast events per subscriber, dropping older events when the buffer fills. | Production code that prefers loss-of-history over memory growth under contention. The default. |
| `.bufferingOldest(N)` | Retain at most `N` oldest-broadcast events per subscriber, dropping newer events when the buffer fills. | Audit pipelines that care about the *first* burst more than the latest tail (rare). |
| `.unbounded` | Buffer every event until the subscriber drains it. | Test harnesses or short-lived subscribers where you control lifetime and require deterministic, lossless ordering. |

## Configuring supported stores

For Navigation, Modal, and Flow stores, the policy is set at construction
time via the store's configuration:

```swift skip doc-fragment
let store = try NavigationStore<HomeRoute>(
    initialPath: [.list],
    configuration: NavigationStoreConfiguration(
        eventBufferingPolicy: .bufferingNewest(2048)
    )
)
```

Modal and Flow stores expose the same knob, with one policy per
published stream:

- `NavigationStoreConfiguration.eventBufferingPolicy`
- `ModalStoreConfiguration.eventBufferingPolicy`
- `FlowStoreConfiguration.eventBufferingPolicy` for the flow-level
  `FlowStore.events` fan-out
- `FlowStoreConfiguration.navigation.eventBufferingPolicy` and
  `FlowStoreConfiguration.modal.eventBufferingPolicy` for the wrapped
  inner store streams

`SceneStore` does not currently expose a buffering configuration. Its events
stream always uses `EventBufferingPolicy.default`.

## Drop semantics under load

Under sustained backpressure, the store keeps emitting events. Whether
the event reaches a slow subscriber depends on the policy chosen for
that subscriber's store:

- `.bufferingNewest(N)`: oldest events are dropped silently. The
  subscriber sees a contiguous tail of the most recent N events the
  store emitted.
- `.bufferingOldest(N)`: newer events are dropped silently after the
  buffer fills. The subscriber sees the first N events emitted after
  it started subscribing.
- `.unbounded`: nothing is dropped, but the per-subscriber queue can
  grow without bound while the subscriber falls behind.

Drops are not surfaced as an event. If your analytics pipeline must
distinguish "no event happened" from "an event was buffered out", use
`.unbounded` for that subscriber and rely on your own pacing rather
than the broadcaster.

## Lifetime contract

Each subscriber owns one `AsyncStream`. When the subscriber's
iterator goes out of scope, `AsyncStream.Continuation.onTermination`
fires and the broadcaster removes that slot from its private
continuation storage. When a store releases its broadcaster, that
storage deinitializes, snapshots any outstanding continuations, and
finishes them outside the broadcaster's actor-isolated deinitializer.
Cancelling the consumer task also terminates the subscription. Tie that task to
the owning feature or scene; `for await` loops additionally terminate naturally
when their store is released.

## Related

- <doc:Middleware-and-Cancellation>
- <doc:Rejection-Reasons>
