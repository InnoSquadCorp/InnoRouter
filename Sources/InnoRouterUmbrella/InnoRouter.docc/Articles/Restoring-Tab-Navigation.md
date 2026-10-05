# Restoring tab navigation after an app update

Restore saved navigation into the tab catalog the application renders now.

## Availability

Explicit tab-topology restoration first shipped in InnoRouter 6.1.0. This guide
and the current example use the **InnoRouter 7** host descriptor APIs. Restore
overloads remain exact unless a topology is supplied; a configured host
contract rejects incompatible candidates before commit.

The complete [TabRestorationExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/TabRestorationExample.swift)
uses one `import InnoRouter`, a Codable `@Router` enum, file storage, a
restoration driver, and a native tab host. The example source itself is compiled
by the package; its session is exercised by integration tests.

## Keep one catalog and one store

Create a `RouterTabCatalog` from the enum's generated `routerTabs`. Use that
same catalog for `RouterTabRestorationTopology(catalog:)`, the Store's
`catalog.hostDescriptor(orphanPolicy: .preserveDormant)`,
and the host. Create the initial current-tab state explicitly; the empty
`makeRouterStore()` convenience remains a root stack. Retain
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

The legacy `RouterSnapshotCodec` now defaults to finite provisional limits:
4 MiB encoded, 2 MiB payload, 128 JSON object/array levels, and 262,144 tokens
(including punctuation). `RouterFileSnapshotStorage` defaults to the same
4 MiB encoded limit. These values have not been calibrated against every app;
measure representative snapshots before choosing larger finite overrides.
Use the encoded limit for both storage and the codec, and set a payload limit
that fits the application's route state:

```swift compile
import InnoRouter

enum AppRoute: Route, Codable {
    case home
}

let snapshotURL = FileManager.default.temporaryDirectory
    .appending(path: "router-snapshot.json")
let limits = try RouterSnapshotLimits(
    maximumEncodedByteCount: 2 * 1_024 * 1_024,
    maximumPayloadByteCount: 1 * 1_024 * 1_024
)
let codec = try RouterSnapshotCodec<AppRoute>(currentVersion: 1, limits: limits)
let storage = try RouterFileSnapshotStorage(
    fileURL: snapshotURL,
    maximumByteCount: limits.maximumEncodedByteCount
)
```

The storage limit prevents a complete oversized file allocation. Before typed
JSON decoding, the codec screens the envelope and payload for byte, depth and
token limits and duplicate keys. It screens each migration output before the
next migration or final state decoder can consume it. The numeric values in the
example are application-selected overrides. Explicit `limits: nil` opts out of
the codec's byte limits and JSON preflight, so it does not provide the bounded
decoding guarantee. Selecting nil on the file adapter separately opts out of
its file bound. Keep original bytes and validate real legacy migration fixtures;
finite defaults alone do not establish application-specific compatibility.

Existing byte-limit error cases remain available. Complexity and duplicate-key
failures use `RouterSnapshotError.preflight` with extensible, payload-free codes
and details; handle unknown codes with a fallback. Recovery remains explicit.

In the PR54 groundwork carried into InnoRouter 7, a file over the storage limit reaches the driver's
`RouterSnapshotRecoveryPolicy` exactly like an envelope the codec rejects. The
default `.fail` fails activation and preserves the file; `.use` receives the
typed `encodedDataTooLarge` reason and submits the application's fallback as
the restore request. That request passes through normal policies, which can
reject or defer it, so inspect `outcome.transition` as for any restore. An
untyped storage failure, such as a denied file permission, says nothing about
the snapshot and still fails activation.

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
`try RouterTabHost(store: store, catalog: catalog, orphanPolicy: .preserveDormant)`.
Set the Store's `configuration.hostDescriptor` to
`catalog.hostDescriptor(orphanPolicy: .preserveDormant)` during setup. This
freezes the catalog's root Route values as well as its shape and orphan policy. Both supplied-store overloads throw. Their default
policy is `.reject`; it must match the Store declaration. Preservation still
rejects a non-stack current scope or a selection outside the rendered catalog.
Construction never registers a contract, reconciles state, or invents a scope.

Keeping a scope ID while changing its root Route is a semantic contract change,
even when every branch still has the same shape. Use the owner's explicit
`replaceHost(with:descriptor:context:)` to atomically replace the state plan and
new catalog descriptor, then mount its matching host. The prior scopes lose
authority. Changing a label, localized title, or icon alone does not change the
root Route mapping.

Topology reconciliation is not a payload migration or a tab-renaming map.
Labels and order do not change identity. Before renaming a tab route case, add
an explicit persisted identity such as
`@TabItem("Settings", systemImage: "gear", id: "settings")`; the generated
typed tab remains the renamed case while `routerScopeID` stays `settings`.
Explicit and default IDs must be unique. This stabilizes the branch ID only. If
the renamed route case is also encoded inside a path or other payload, define
an explicit snapshot schema migration or recovery policy. The example keeps
codec version `1` because adding/removing empty tab scopes alone does not change
its route encoding. A state supplied by `RouterSnapshotRecoveryPolicy.use` is
the application's final fallback and is not reconciled again.

## Handle outcomes and errors separately

Observe `driver.status` for loading, saving, and storage/decoding failures.
Inspect `driver.lastActivation` for a missing snapshot or the restore result.
For a restored result, inspect `outcome.transition`: `.applied`, `.unchanged`,
`.rejected`, and `.deferred` have different meanings. A nonthrowing return does
not prove that saved navigation was applied. A newer navigation commit can
make an in-flight restore stale; preserve the newer state rather than retrying
the old snapshot over it.

The example uses the driver's partial-validation initializer. Decode,
migration, and validation failures remain visible without silently discarding
the saved file; this mode does not apply a recovery fallback. Applications
decide whether to offer retry, reset, or a schema migration. If an application
adds deferring policies, it must resolve or cancel the deferred request and
observe its terminal outcome rather than treating `lastActivation` or
`lastPartialRestoration` as a live policy-completion feed.

When initial loading, decoding, migration, or validation fails, the lifecycle
modifier preserves the existing file instead of flushing the Store's
pre-restore value over it. A later independent navigation commit establishes a
new state that may be saved normally. Applications can still make an explicit
choice with `save()` or `removeSnapshot()` after presenting retry or reset UI.

For a one-shot route-level keep/drop/replace validation, use
`restorePartially(from:using:validator:tabTopology:validationTimeout:expectedRevision:)`.
Its `report.topologyChanges` describes inserted scopes, ordering, and selection
changes in the proposed candidate. Always inspect `transition` as well: a
report can describe a candidate that was rejected. For automatic persistence,
pass the same validator, timeout, and optional topology to
`RouterRestorationDriver`. Its `lastPartialRestoration` describes the initial
attempt. Accepted normalized candidates are saved even when their Store
transition is unchanged; deferred candidates are saved only after approval.

## Try the upgrade and reopen flow

Follow the [example setup guide](https://github.com/InnoSquadCorp/InnoRouter/blob/6.1.0/Examples/README.md#tab-restoration-610)
to mount the view and optionally write a previous-version demo snapshot before
launch. Select Settings, open a detail, save, and reopen using the same URL.
The new session restores both the new path and the preserved orphan subtree.

The automated example tests cover first launch, old-catalog reconciliation,
navigation in the new tab, file save/reopen with a new session, and malformed
file preservation. They do not claim OS process-relaunch or native gesture QA.
