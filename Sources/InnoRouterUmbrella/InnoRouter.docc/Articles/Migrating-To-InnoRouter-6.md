# Migrating to InnoRouter 6

InnoRouter 6 deliberately replaces the parallel 5.x routing authorities with
one macro-first state/store model. This is a breaking migration, not a set of
deprecated aliases.

## Dependency

Replace granular runtime products with the umbrella product:

```swift skip package-manifest-fragment
.product(name: "InnoRouter", package: "InnoRouter")
```

Add `InnoRouterTesting` and `InnoRouterInspector` only to targets that use them.

## Route declaration and host

Before, an application could manually compose separate stack and modal stores.
In 6.0, declare destinations once and choose a native host:

```swift skip doc-fragment
import InnoRouter
import SwiftUI

@Router
enum AppRoute {
    case home
    case detail(id: String)

    var destination: some View { /* exhaustive switch */ }
}

RouterHost(AppRoute.self) {
    AppRoute.destination(for: .home)
}
```

Use `AppRoute.makeRouterStore()` and `RouterHost(store:)` only when an app
boundary must retain the authority.

## Request vocabulary

| 5.x | 6.0 |
| --- | --- |
| independent stack/modal/flow stores | `RouterStore<Route>` |
| navigation, modal, and flow intents | `RouterAction<Route>` |
| navigation and flow plans | `RouterPlan<Route>` |
| direct inner-store mutation | `await store.perform(action)` |
| separate store event types | `RouterEvent<Route>` with one transition ID |

Named environment helpers such as `go`, `back`, `sheet`, and `cover` remain
convenient projections of `RouterAction`; they do not form another public
request language.

The repository's `MigrationSmoke` fixture compiles the exact published 5.2.1
`NavigationStore` scenario and this 6.0 replacement as separate downstream
packages, then compares their encoded final path. It intentionally proves a
migration rather than preserving the removed type names.

## Tabs and split layouts

Replace per-tab stores with branches in one `RouterState` tree. Apply
`@TabItem` only to parameterless tab roots; ordinary detail routes can remain
unmarked in the same `@Router` enum. `RouterTabHost` creates and scopes the
branches. The macro-generated scope ID is based on the case name and is safe to
persist across localization and reordering.

For an app-retained split tree, construct `RouterContainerState(style: .split,
...)`, create one `RouterStore`, and pass it to `RouterSplitHost` or
`RouterThreeColumnSplitHost`. `RouterSplitState` persists native visibility and
preferred compact column alongside the two- or three-column scope topology.

## Async policy

Replace middleware executors with ordered `RouterPolicy` values:

```swift skip doc-fragment
let policy = RouterPolicy<AppRoute>(name: "session") { transition in
    session.isAuthenticated ? .allow : .reject("authentication-required")
}

let store = AppRoute.makeRouterStore(
    configuration: .init(policies: [policy])
)
```

Policies inspect an immutable candidate. Do not mutate navigation or business
state from a policy closure.

When approval must arrive later, return `.deferRequest(id)`. The store releases
its execution lane and exposes payload-safe metadata in `deferredTransitions`.
Resolve the request explicitly; unchanged-state resume is the default, and
rebasing on current state must be selected deliberately.

## Deep links

Replace push-only or flow-only pipelines with `RouterLinkPipeline`. A route
matcher is promoted to an exact root-stack plan by default; pass a plan matcher
or planner closure for tabs, presentations, windows, or immersive state.

Authentication evaluates every route in the target tree. A pending decision
retains the complete plan, so replay does not reconstruct intent chains. Put
that value in `RouterPendingLinkSlot`, then call `resume(on:)` after login;
replacement, cancellation, and rejection retention are explicit.

Authentication state may be isolated to any actor. Its closure and the final
decision are therefore asynchronous:

```swift skip doc-fragment
let pipeline = RouterLinkPipeline<AppRoute>(
    originPolicy: originPolicy,
    matcher: matcher,
    authenticationPolicy: .required(
        shouldRequireAuthentication: { $0.requiresSession },
        isAuthenticated: { await session.isAuthenticated }
    )
)

let decision = await pipeline.decide(for: url)
```

## Persistence

Replace raw stack/flow encoding with `RouterSnapshotCodec<Route>`:

```swift skip doc-fragment
let codec = try RouterSnapshotCodec<AppRoute>(currentVersion: 2, migrations: [v1ToV2])
let data = try await store.snapshot(using: codec)
let result = try await store.restore(from: data, using: codec, recovery: .fail)
```

Migrations must be adjacent and deterministic. Choose `.fail` or an explicit
app fallback; 6.0 never silently restores an empty router.

Prefer `RouterSnapshotMigration.codable(from:to:decoding:transform:)` when the
legacy payload has a known shape. It decodes an app-owned legacy DTO and
encodes the next payload with stable key ordering, avoiding fragile raw JSON
string rewrites.

Snapshot encoding and decoding execute away from the main actor. Restoration
also captures the current revision before loading and rejects the decoded plan
as stale if the live router commits while storage is being read.

When the app wants lifecycle-driven persistence, retain a
`RouterRestorationDriver` with an app-selected `RouterSnapshotStorage` and
attach `routerStateRestoration(_:)` at the root. The driver still restores
through the canonical policy pipeline and does not select a cloud service or
storage location.

Persist an authentication continuation separately with
`RouterPendingLinkPersistenceDriver` and app-selected
`RouterPendingLinkStorage`. It stores the exact pending plan, not the source URL
alone, and refuses to overwrite a newer in-memory submission after a slow load.

## Macro-first state reads

Keep ordinary destinations on `@EnvironmentRouter` for actions. Replace direct
store injection used only for UI state with `@EnvironmentRouterState`; its
`RouterStateReader` exposes read-only stack, presentation, tab, badge, window,
and immersive projections from the same nearest scope.

## Result-bearing presentation

Replace child-coordinator callbacks with one exact presentation lifetime:

```swift skip doc-fragment
let outcome: RouterPresentationOutcome<Profile> = await router.present(
    .profileEditor,
    expecting: Profile.self
)
```

The destination calls `finishPresentation(returning:)`. Treat `.dismissed`,
`.cancelled`, and `.rejected` as separate terminal states.

## Tests and inspection

- Replace per-store test harnesses with `RouterTestStore`.
- Attach `RouterInspectorRecorder` to the canonical `RouterStore`.
- Expect `started`, one event per prepared policy, and one terminal event with
  the same transition identifier.
- Read source, animation, and metadata from the `context` carried by every
  terminal event; terminal diagnostics no longer infer `.programmatic`.
- Default inspector metadata is structural and redacted. Supply a formatter
  only when the app explicitly accepts payload exposure.
- Import exported sessions into the recorder or use `RouterInspectorPlayback`
  and `RouterInspectorComparison` for offline step-through diagnosis.
- Use bookmarks, correlated elapsed/duration metadata, arbitrary state
  comparison, and pause-on-rejection to isolate a failing transition. JSON file
  import remains a developer-only, non-mutating workflow.

## Removed without an automatic adapter

The 5.x coordinator callback lifecycle, modal queues, effect handlers, and
automatic scene ownership cannot be translated safely into aliases: they have
different lifetime and atomicity semantics. Move business effects outside the
router, model the visible target as `RouterState`, and invoke native window or
immersive APIs through a macro-generated `RouterSceneRoute` catalog when
committed state changes. Scene actions on unconstrained route types are no
longer part of the public surface. Native open failures are repaired through
the normal reducer and event path, but that corrective removal cannot be
rejected by an application policy because the failed scene does not exist to
preserve.

Each native scene now owns a recursive `RouterNode` within that same state.
Use the macro-generated typed `Route.Scene` request and render the matching
`RouterWindowHost` or `RouterImmersiveSpaceHost`; do not host a second store in
the scene.
