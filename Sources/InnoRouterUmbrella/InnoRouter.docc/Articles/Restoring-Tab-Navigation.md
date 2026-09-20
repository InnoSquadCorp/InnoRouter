# Restoring tab navigation after an app update

Restore saved navigation into the tab catalog the application renders now.

## Availability

Explicit tab-topology restoration is an **unreleased 6.1 addition**. The
published 6.0.0 package does not contain these APIs. The existing restore
overloads continue to apply the snapshot exactly unless a topology is supplied.

The complete [TabRestorationExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/TabRestorationExample.swift)
uses one `import InnoRouter`, a Codable `@Router` enum, file storage, a
restoration driver, and a native tab host. The example source itself is compiled
by the package; its session is exercised by integration tests.

## Keep one catalog and one store

Create a `RouterTabCatalog` from the enum's generated `routerTabs`. Use that
same catalog for `RouterTabRestorationTopology(catalog:)` and the host. Retain
the store and driver across view updates, as the example does with a session
held in `@State`. Do not reconstruct them inside `body`.

Pass the topology to `RouterRestorationDriver` and attach
`routerStateRestoration(_:)` to the host's stable root. The modifier owns the
driver's attachment: it restores on initial activation, observes committed
navigation, coalesces saves, and flushes when the scene leaves the active phase.
The example's Save now button also awaits an explicit save before reporting
success. An abrupt process termination is not a guaranteed opportunity to save.

Choose a stable, application-owned file URL. Reuse it on the next launch, and
use separate files for independently owned scenes or accounts. The driver
executes storage operations off the main actor. Replacing the catalog requires
ending the old driver's ownership and creating a new driver with the new
topology; changing a view's catalog alone does not reconfigure a driver.

## Understand what changes during reconciliation

The example's old snapshot contains `home` and `legacy`, with `legacy` selected.
Its current catalog contains `home` and the newly introduced `settings` tab.

| Saved input | Restored result |
| --- | --- |
| `home` has a saved detail | The detail and the scope's other saved data remain intact. |
| No `settings` branch | An empty, selectable stack is inserted. |
| `legacy` is absent from the current catalog | Its subtree is preserved after current scopes but is not rendered as a tab. |
| Selection points to `legacy` | Selection falls back to the first current scope, `home`. |

Render this state with
`RouterTabHost(store:catalog:allowingOrphanedBranches: true)`. The existing
manual `init(store:catalog:)` intentionally requires an exact branch set. The
orphan-tolerant initializer still rejects a non-stack current scope or a
selection outside the current catalog.

Topology reconciliation is not a payload migration or a tab-renaming map.
Keep stable tab identities when only labels change. If route payloads or the
root container shape change, define an explicit snapshot schema migration or
recovery policy. The example keeps codec version `1` because adding/removing
empty tab scopes alone does not change its route encoding. A state supplied by
`RouterSnapshotRecoveryPolicy.use` is the application's final fallback and is
not reconciled again.

## Handle outcomes and errors separately

Observe `driver.status` for loading, saving, and storage/decoding failures.
Inspect `driver.lastActivation` for a missing snapshot or the restore result.
For a restored result, inspect `outcome.transition`: `.applied`, `.unchanged`,
`.rejected`, and `.deferred` have different meanings. A nonthrowing return does
not prove that saved navigation was applied. A newer navigation commit can
make an in-flight restore stale; preserve the newer state rather than retrying
the old snapshot over it.

The example uses `.fail` recovery and surfaces failures without silently
discarding the saved file. Applications decide whether to offer retry, reset,
or a schema migration. The example does not install deferring policies; if an
application adds them, it must resolve or cancel the deferred request and
observe its terminal outcome rather than treating `lastActivation` as a live
policy-completion feed.

For route-level keep/drop/replace validation, use
`restorePartially(from:using:validator:tabTopology:validationTimeout:expectedRevision:)`.
Its `report.topologyChanges` describes inserted scopes, ordering, and selection
changes in the proposed candidate. Always inspect `transition` as well: a
report can describe a candidate that was rejected. A plain automatic driver
restore does not produce this partial-restoration report.

## Try the upgrade and reopen flow

Follow the [example setup guide](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/README.md#tab-restoration-unreleased-61)
to mount the view and optionally write a previous-version demo snapshot before
launch. Select Settings, open a detail, save, and reopen using the same URL.
The new session restores both the new path and the preserved orphan subtree.

The automated example tests cover first launch, old-catalog reconciliation,
navigation in the new tab, file save/reopen with a new session, and malformed
file preservation. They do not claim OS process-relaunch or native gesture QA.
