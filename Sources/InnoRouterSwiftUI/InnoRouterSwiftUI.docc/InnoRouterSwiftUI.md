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

Partial restoration validates decoded routes before one revision-checked
commit and returns a payload-free structural report. A fully removed nonempty
stack requires an app-provided, revalidated fallback.

The explicit tab topology APIs are unreleased additions for 6.1.

Restoration is exact. A snapshot written before a tab existed carries no branch
for it, so that tab stays unreachable. `RouterTabRestorationTopology` states
the scopes the application renders now, as an explicit argument to
`RouterStore.restore`, `RouterStore.restorePartially`, and
`RouterRestorationDriver.init`. It carries ordered scope identity only, so
reconciliation adds empty scopes and never moves routes, presentations, or
badges into a restored state. Branches the topology does not name are kept as
orphans for a later catalog, and a selection it no longer names falls back to
its first scope. A state returned by `RouterSnapshotRecoveryPolicy.use` is the
application's final answer and is applied without reconciliation. Tab-aware
requests capture their starting revision before decoding. Public reconciliation
validates mutable state and current stack shapes before preparing a candidate.
Partial reports include payload-free `topologyChanges`; their transition outcome
determines whether the candidate was applied. Older reports decode with an empty
change list.

`RouterHistory` reuses
the same validator, exact plans, and policies for navigation-only moves. It
observes commits synchronously, tracks deferred destinations by entry identity,
invalidates old-session work, and preserves live badges and presentations,
rejects modal path conflicts, and never changes scene inventory. Multiple active
histories on one Store follow successful history-originated navigation while
retaining independent capacities, checkpoints, and session keys. Session
boundaries are app-defined through `reset(sessionKey:)`.
