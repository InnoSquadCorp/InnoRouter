# InnoRouterSwiftUI

The native SwiftUI rendering layer for InnoRouter's macro-first state model.

## Overview

Use `@Router` to declare route data and destinations. `RouterHost`,
`RouterTabHost`, and `RouterSplitHost` render a single `RouterStore`; child
views send typed actions through `@EnvironmentRouter`.
Views read the same nearest scope through `@EnvironmentRouterState`; its
`RouterStateReader` exposes no mutation methods.

The canonical runtime consists of:

- `RouterState<Route>` for the complete visible hierarchy;
- `RouterAction<Route>` for incremental requests;
- `RouterPlan<Route>` for exact targets;
- `RouterStore<Route>` for reduce, async prepare, and atomic commit;
- `RouterScope<Route>` for stable, read-only subtree projections;
- `RouterRestorationDriver<Route>` for opt-in app-selected persistence;
- `RouterHistory<Route>` for opt-in bounded navigation-only checkpoints.

A host owns its store by default. Retain and inject a store at an application
boundary only for restoration, policies, inspection, or direct observation.

## Basic host

```swift skip doc-fragment
@Router
enum AppRoute {
    case detail(id: String)

    var destination: some View { /* exhaustive switch */ }
}

RouterHost(AppRoute.self) {
    HomeView()
}
```

`RouterHost` owns push navigation and one sheet or full-screen presentation per
stack. Every accepted transition commits one state value. Every refusal returns
a typed reason without partial state.

## Native composition

| Need | Surface |
| --- | --- |
| stack and presentation | `RouterHost` |
| tabs and independent branch history | `RouterTabHost` |
| two-column split tree | `RouterSplitHost` |
| three-column split tree | `RouterThreeColumnSplitHost` |
| regular-window local history | `RouterWindowHost` |
| immersive-space local history | `RouterImmersiveSpaceHost` |
| attributed native immersive scene declaration on visionOS | `RouterImmersiveSpaceScene` |
| application-owned authority | `RouterStore` |
| child subtree | `RouterScope` |
| macro-first read-only state | `EnvironmentRouterState` |
| pending authenticated link | `RouterPendingLinkSlot` |
| durable pending link | `RouterPendingLinkPersistenceDriver` |
| automatic app-selected restoration | `RouterRestorationDriver` |
| app-validated partial restoration | `RouterStore.restorePartially` |
| restoring into the current tab catalog | `RouterTabRestorationTopology` |
| bounded back/forward and checkpoints | `RouterHistory` |

`@TabItem` marks only parameterless tab roots. Unmarked associated-value cases
remain ordinary push or presentation destinations in the same route enum.
Selected images and native search roles remain tab metadata, not identity.

Use the atomic stack helpers for idempotent producer behavior and attach a
`RouterRequestKey` when queued duplicates should use keep-first or
replace-pending semantics. A `RouterPolicy` can defer a transition while the
store continues unrelated work; resolving that deferral explicitly resumes,
rejects, or cancels the immutable request.

On visionOS, declare `RouterImmersiveSpaceScene(id:store:)` beside a matching
`RouterSceneDriver`. The native value binds appearance to one Store, lifetime,
open request, and driver owner without requiring a Codable route. A matching
appearance after committed failure repair enters the regular authorization and
policy pipeline and receives a new revision and scope; expired scope authority
never revives. Existing id-only scene declarations retain their original
behavior. Declare each wrapper ID once for a stable Store in the app scene
graph; conditional declaration removal is not modeled.

Partial restoration validates decoded routes before one revision-checked
commit and returns a payload-free structural report. A fully removed nonempty
stack requires an app-provided, revalidated fallback.

The explicit tab topology APIs are available in 6.1.0 and later.

Restoration is exact unless a topology is supplied. In 7.0, a host-configured
Store rejects a snapshot missing a required current tab instead of committing
an unreachable renderer. `RouterTabRestorationTopology` states
the scopes the application renders now, as an explicit argument to
`RouterStore.restore`, `RouterStore.restorePartially`, and
`RouterRestorationDriver.init`. It carries ordered scope identity only, so
reconciliation adds empty scopes and never moves routes, presentations, or
badges into a restored state. Reconciliation retains branches the topology does
not name as orphans for a later catalog. Committing and rendering those branches
requires both the Store descriptor and renderer to opt into `.preserveDormant`;
such branches cannot become selected renderers. A selection the current topology
no longer names falls back to its first scope. A state returned by
`RouterSnapshotRecoveryPolicy.use` is the
application's final answer and is applied without reconciliation. Tab-aware
requests capture their starting revision before decoding. Public reconciliation
validates input state and current stack shapes before preparing a candidate.
Partial reports include payload-free `topologyChanges`; their transition outcome
determines whether the candidate was applied. Older reports decode with an empty
change list.

Automatic restoration can take the same validator, timeout, and optional
topology. It plans before one policy transition and exposes the initial report
through `lastPartialRestoration`. Accepted normalized state is persisted,
including an unchanged Store transition whose source file still required
cleanup. Deferred candidates are persisted only after terminal approval. This
partial driver mode reports decode and validation failures and does not apply a
snapshot recovery fallback.

`RouterHistory` reuses
the same validator, exact plans, and policies for navigation-only moves. It
observes commits synchronously, tracks deferred destinations by entry identity,
invalidates old-session work, and preserves live badges and presentations,
rejects modal path conflicts, and never changes scene inventory. Multiple active
histories on one Store follow successful history-originated navigation while
retaining independent capacities, checkpoints, and session keys. Session
boundaries are app-defined through `reset(sessionKey:)`.
