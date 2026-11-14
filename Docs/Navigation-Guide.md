# InnoRouter 7 navigation reference

Current 7.0.0 reference. Start with the [quick start](../README.md). Historical release checks do not imply new validation.

Contextual fragments are independent examples. Snapshot examples require a
`Codable` `AppRoute` and app-provided values such as `snapshotURL` and `HomeView`.

## One runtime model

```swift skip doc-fragment
let store = AppRoute.makeRouterStore()

let outcome = await store.perform(.push(.detail(id: "42")))
```

In 7.0, `RouterStore()` and `AppRoute.makeRouterStore()` remain nonthrowing.
Supplying `initialState`, `initialPath`, or `configuration` requires `try`:
initial admission rejects structural, scene-catalog, and resource errors instead
of trapping or truncating. Supplied-store tab and split hosts also throw and
require `configuration.hostDescriptor`; construction validates without
registering or changing the Store. The source-compatible stack host exposes a
`validationFailure` and renders recovery UI when that contract is missing or
incompatible. See the [initialization contract](../Docs/7.0.0-store-initialization-contract.md).

Each request follows `reduce → prepare → commit`. A policy rejection,
cancellation, stale preparation, or invalid action leaves committed state
unchanged. Applied transitions assign one complete `RouterState` value and
increment the store revision once.

Use `goIfNeeded`, `backOrGo`, and `replaceTop` for atomic idempotent stack
changes. For bursty producers, attach a `RouterRequestKey` and choose
`keepFirst` or `replacePending`; unrelated requests retain FIFO order. A policy
may return `deferRequest` to release the execution lane while the app awaits an
external decision, then resume revision-safely or explicitly rebase on current
state.

`RouterActions` methods such as `go`, `back`, and `sheet` return a task and, by
default, commit on a later main-actor turn. Set
`configuration.dispatchTiming = .immediateWhenIdle` to commit before the call
returns, so a surrounding `withAnimation` or `withTransaction` applies to the
navigation change itself. A request commits immediately only when the store has
no prepare policy and no authorization, no other request is in flight or still
on its way from an earlier fire-and-forget call, the call is not made from
inside a `RouterEvent` or request observer callback, and the calling task is not
cancelled; every other request takes the deferred path, so call order and policy
guarantees are unchanged. Requests through a feature projection, and
`dismiss()` or `setPresentationDetent(_:)` called from inside presented content,
always take the deferred path. The store cannot see a request your own code
starts in a `Task`, so an immediate request made later in the same turn commits
before it. Call from a user-interaction handler such as a button action, not
while a view body is being evaluated.

`router.transaction { ... }` applies its steps to the state the store holds
when the request executes, so it builds on the fire-and-forget requests made
before it. An invalid transaction still throws at the call. Through a feature
projection the transaction replaces that feature's subtree with a plan built at
the call, as before.

Long-running or bursty producers can bound every retained stage explicitly:

```swift skip doc-fragment
let configuration = RouterStoreConfiguration<AppRoute>(
    maximumPendingRequestCount: 128,
    requestOverflowStrategy: .rejectNewest,
    policyTimeout: .seconds(5),
    deferrals: .init(
        maximumPendingCount: 32,
        timeToLive: .seconds(600),
        overflowStrategy: .cancelOldest
    )
)
```

Overflow, timeout, eviction, and expiry return distinct
`RouterRejectionReason` values and complete any awaiting presentation exactly
once. Caller cancellation wins immediately even when a policy implementation
does not cooperatively observe task cancellation.

Use `RouterScope` to observe or act on a tab or split subtree. A scope is a
stable projection and forwarder, never a second mutable store.

`@EnvironmentRouterState` is the macro-first read surface. It exposes a
read-only, observation-aware `RouterStateReader` with narrow properties such as
`path`, `canGoBack`, `presentation`, tab selection, and badges. It never creates
a second authority.

Independent feature packages keep their own route enum and declare no app
dependency. The app composition root wraps the associated-value case with
`@FeatureRoute`; the generated mapping installs child actions and state without
creating a child store:

```swift skip doc-fragment
@Router
enum AppRoute {
    @FeatureRoute("account.primary")
    case account(AccountRoute)

    var destination: some View {
        RouterFeatureHost(AppRoute.Feature.account) {
            AccountRoot()
        }
    }
}
```

Inside `AccountRoot`, the usual `@EnvironmentRouter(AccountRoute.self)` and
`@EnvironmentRouterState(AccountRoute.self)` APIs use the parent store's same
policy, queue, transition ID, revision, and commit. The feature projection must
own its complete subtree; mixed parent/child route values fail explicitly.
Opening or dismissing application windows and immersive spaces remains a
parent composition-root responsibility.

Generated mappings remain under `AppRoute.Feature` (for example,
`AppRoute.Feature.account`). Structural feature metadata is exposed separately
as `AppRoute.routerFeatureCatalog`, so an app may freely declare a feature case
named `catalog`. Recursive feature payloads may use `Self`, including in nested
generic routers. An associated-value case named `routerFeatureCatalog` remains
a normal overload; only a parameterless case conflicts with the generated
metadata property.

For opt-in persistence, combine a versioned codec with app-selected storage:

```swift skip app-lifecycle-fragment
let store = try AppRoute.makeRouterStore(
    configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    ))
)
let driver = RouterRestorationDriver(
    store: store,
    codec: try RouterSnapshotCodec(
        currentVersion: 1,
        limits: RouterSnapshotLimits(
            maximumEncodedByteCount: 2 * 1_024 * 1_024,
            maximumPayloadByteCount: 1 * 1_024 * 1_024
        )
    ),
    storage: try RouterFileSnapshotStorage(
        fileURL: snapshotURL,
        maximumByteCount: 2 * 1_024 * 1_024
    )
)

RouterHost(store: store) { HomeView() }
    .routerStateRestoration(driver)
```

The driver restores through normal policies, coalesces committed-state writes,
and flushes when the scene becomes inactive. Storage and cloud synchronization
remain explicit application choices. Observation begins when activation is
reserved, so navigation committed while snapshot loading is pending is not
overwritten. That newer state is also what the driver saves next, so the
snapshot that lost is replaced.

When launch-time work must not displace the previous session, wait until the
driver reports `lastActivation` before committing it, or create the driver with
`initialRestorePrecedence: .snapshot`. With that option, when no request is
running or queued as activation starts, the driver holds the store's execution
lane until its restore request runs, through loading, decoding, migration, and
validation: requests made meanwhile wait under `.serialize` or are rejected as
busy under `.rejectWhileBusy`. If a request was already running or queued, the
driver holds nothing; that activation behaves as the default, and once the
earlier request commits, the restore is rejected as stale.

What the waiting requests do depends on how the hold ends:

- **The snapshot is restored** (the restore applies or leaves the state
  unchanged). Every scope is replaced, so a request from a view—a router call,
  a host's deep-link handling, a SwiftUI navigation binding—was made for a
  scope that no longer exists and is rejected as an expired scope, as after
  any restore: an early tap or launch link ends as a rejected request instead
  of erasing the session. A request sent to the store itself is not tied to a
  scope: it runs after the restore and can change or replace the restored
  state, including link handling through `handle(_:using:)`, whose default
  plan replaces the whole state.
- **There is no snapshot, the load fails, or the driver stops.** Nothing
  replaced the scopes, so the waiting requests run on the current state.
- **A policy or authorization defers or rejects the restoration transition.**
  The hold ends with that outcome: the waiting requests run on the state
  before the snapshot, and what they commit is saved.

Keep the storage's load bounded and give a validator a `validationTimeout`,
because navigation is closed for the duration.

Stopping a driver invalidates queued workers and caller ownership; a later
activation cannot be modified by their delayed completion.

A store that something besides its host needs, such as this driver, can be
created already declared for the default hosts:
`AppRoute.makeRouterHostStore()` (or `try AppRoute.makeRouterHostStore(configuration:)`)
for `RouterHost(store:)`, and `try AppRoute.makeRouterTabHostStore()` for
`RouterTabHost(store:)`. Pass `orphanPolicy: .preserveDormant` to the tab
factory, and the same policy to the host, when a restored snapshot may still
hold a tab the catalog no longer declares.

The byte limits above are application-selected examples. File storage rejects
oversized input while reading, and the codec independently bounds the encoded
envelope, decoded payload, and every migration result. The provisional 7.0
defaults are 4 MiB encoded/file bytes and 2 MiB decoded payload, with JSON depth
128 and 262,144 tokens. Explicit nil opts out; actual-app calibration remains
a release gate. In the PR54 groundwork carried into 7.0, a file
over the storage limit reaches the driver's recovery policy exactly like an
envelope the codec rejects: the default `.fail` fails activation and preserves
the file, while `.use` restores the application's fallback through normal
policies, so inspect the activation's `transition` as for any restore.

For snapshots containing retired destinations,
`restorePartially(from:using:validator:validationTimeout:)` decodes and migrates
first, asks the app to keep, remove, or replace each route, and commits one
exact plan at the captured revision. Invalid stack predecessors remove their
dependent suffix while valid siblings and existing scenes survive. The report
contains every keep/remove/replace decision with locations and app-owned reason
codes, not route values. If validation removes an entire previously nonempty
stack, restoration fails unless the app provides a fallback route through
`RouterPartialRestorationValidator(fallback:validate:)`; that fallback is
validated once before it can enter the plan.

The automatic driver also accepts a required `validator`, optional
`validationTimeout`, and optional `tabTopology`. It performs the same partial
planning before one policy transition, exposes the initial result through
`lastPartialRestoration`, and saves only accepted normalized state. This mode
does not apply a snapshot recovery fallback.

Explicit tab topology first shipped in **6.1.0**. The examples here use the
**7.0** host declaration contract.

The [complete tab restoration example](../Examples/README.md#tab-restoration-700)
connects the catalog, driver, host, file persistence, and result handling.
The [restoration guide](../Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md)
explains tab identity, schema migration, and recovery boundaries.

Restoration is exact unless the app explicitly requests reconciliation. A
snapshot predating a declared tab is rejected by a host-configured Store
instead of rendering an empty, unreachable scope. To add the tabs the app
renders now, state the topology:

```swift skip app-lifecycle-fragment
let topology = try RouterTabRestorationTopology(of: AppRoute.self)

try await store.restore(from: data, using: codec, tabTopology: topology)
```

A scope the snapshot carries keeps its path, presentation, and badge. A scope
it lacks is created empty — no route or badge is invented for it. A branch the
topology does not name is kept after the current scopes, so a later catalog can
still reach it; render such a store with
`RouterTabHost(store:catalog:orphanPolicy: .preserveDormant)` and configure the
Store with `catalog.hostDescriptor(orphanPolicy: .preserveDormant)`.
The Store and renderer must use the same declaration. A selection the
topology no longer names falls back to its first scope. The same parameter
exists on `restorePartially`, where reconciliation runs before validation so
the app sees the candidate that will be applied, and on
`RouterRestorationDriver.init`, where the topology belongs to that driver's
lifetime. A state returned by `RouterSnapshotRecoveryPolicy.use` is the app's
final answer and is never reconciled.

Tab-aware restore captures the request's starting revision, so navigation
committed during decoding makes that restore stale. Public reconciliation
validates the input and rejects a current tab whose node is not a stack.
Partial restoration exposes payload-free `report.topologyChanges` alongside
route entries, including inserted scopes, scope order, and selection changes.
The report describes the candidate; check `transition` to see whether policies
accepted it. Reports encoded before 6.1 decode with no topology changes.

## Tabs and split views

Mark only tab roots with `@TabItem`; associated-value cases can stay in the same
enum as ordinary destinations:

```swift skip doc-fragment
@Router
enum AppRoute {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear", id: "settings")
    case preferences

    case detail(id: String)

    var destination: some View { /* exhaustive switch */ }
}

let tabHost = try RouterTabHost(AppRoute.self, initial: .home)
```

Without `id:`, the case name remains the persisted scope identity. Add an
explicit ID before renaming a tab case to keep its saved branch reachable.
This stabilizes the tab scope only; changing a Codable route case used inside a
saved path still requires a snapshot migration. Effective IDs must be unique.

Create input-bearing hosts in a throwing setup boundary and handle failures
there; SwiftUI `body` stays nonthrowing. Tab and split hosts preserve their full
topology and reject invalid or oversized initialization instead of trapping.
From 7.1.0, `RouterTabHost(AppRoute.self)` builds a tab host from the declared
tabs without `try`, so it can be written directly in `body`: the macro has
already validated the catalog, and a hand-written catalog that is invalid
renders recovery UI and reports `validationFailure`. Inside the enum, write
`SwiftUI.Tab` for SwiftUI's tab content; the bare name means the generated
`AppRoute.Tab` (warning `InnoRouterMacro.W008`).

The macro generates stable case-name scope identifiers, so localization or tab
reordering does not corrupt restored branch history. `@TabItem` can also define
a selected system image and native search-tab role.

`RouterSplitHost` owns independent sidebar and detail histories, while
`RouterThreeColumnSplitHost` adds an independent content column. Visibility and
preferred compact column live in `RouterSplitState` and reconcile through the
same system-origin transition pipeline. Custom column identifiers use the
throwing `RouterTwoColumnSplitLayout` and `RouterThreeColumnSplitLayout` values,
so duplicate, empty, or unavailable column topology is rejected before a host
is constructed. Opaque column closures declare stable `sidebarDeclarationID`,
`detailDeclarationID`, and (for three columns) `contentDeclarationID` values.
Supply those same IDs through `layout.hostRootDeclarations(for:...)` in an
application-owned Store descriptor. Labels, localization, and styling do not
change these semantic IDs.

Macro-generated tab metadata is the default. Advanced integrations that must
conform `RouterTabRoute` manually can first build a throwing `RouterTabCatalog`
and use the catalog-taking `RouterTabHost` initializer; duplicate identities,
scope IDs, root routes, initial tabs, and store topology become typed errors.
Use `catalog.hostDescriptor()` for an application-owned tab Store: it freezes
each scope's root Route value as well as its shape. Keeping a tab ID while
changing its root Route is a contract change and requires the owner's atomic
`replaceHost(with:descriptor:context:)`, followed by a matching renderer.
A shape-only descriptor does not authorize a native tab catalog.

A configured stack descriptor declares `.declarationID("router.root")` at its
root for the default `RouterHost` and bridge factories. An application can
choose another semantic ID and pass it as `rootDeclarationID` to the host or
bridge. Existing nonthrowing APIs remain nonthrowing; declaration mismatch is
reported through `validationFailure` and recovery UI.

## Explicit platform adaptation

`RouterPlatformCapabilities.current` is the public contract for native router
features on the compiling Apple platform. Hosts use the same value when a
requested presentation style or option has no equivalent native rendering.
Each fallback emits a deduplicated `RouterEvent.platformAdapted` event, and the
optional Inspector records a payload-redacted description instead of silently
changing behavior. CI executes this contract on iPhone, iPad, Apple TV, Apple
Watch, and Apple Vision simulators; the macOS package suite exercises it in a
native process.

## Deep links and exact plans

`@DeepLink` generates fail-closed parsing from literal origin allowlists.
`RouterLinkPipeline` promotes a matched route—or accepts a full matcher output—
into the same `RouterPlan` used by transactions and restoration. Authentication
can retain the exact plan as pending without partially navigating.
`RouterPendingLinkSlot` makes replacement, cancellation, and policy-safe resume
explicit; a rejected resume remains pending by default.
When that continuation must survive process termination,
`RouterPendingLinkPersistenceDriver` stores its versioned representation in
application-selected storage. Slow restoration never replaces a newer
in-memory link.

Origins are compared exactly, byte for byte after folding ASCII case only, so a
percent-encoded host that merely resembles an allowed one after Unicode case
mapping or normalization is rejected. A user or password component is rejected
in any form, including one that does not decode. Percent-encoding that is not
valid UTF-8 is never accepted as a value: a path segment a pattern reads then
matches nothing, and a query value is invalid for every type, `String` included,
so a generated route that reads it does not resolve. A query item the route does
not read, or a segment a trailing wildcard swallows, does not decide the match.
In a hand-written mapping, the typed `firstValue(forName:as:)` rejects such a
value; the untyped accessors report it as the empty string.

A host without `linkHandling` applies a resolved link as one ordinary store
request. `RouterHost` shows the route directly above its root, replacing the
previous stack; `RouterTabHost` selects a tab root or pushes onto the selected
tab; split hosts route to the matching column. The exact plan is derived from
the state the store holds when the request executes, so a commit that lands
between URL arrival and execution is preserved. A link the host cannot apply—
for example a push while a sheet covers the stack—yields to another host that
can apply it when the URL arrives; when no host can, it ends as a rejected
request visible through `RouterEvent`, not as a silently dropped URL. Where
several hosts can apply the same URL, the outermost one answers it. The host is
chosen when the URL arrives, so a host that becomes unable to apply the link
before its request runs rejects it without handing it to another host.

Set `inspectorCatalog: true` on `@Router` to generate an opt-in, payload-free
`DeepLinkRouteCatalog` from the resolver's same ordered mappings.
`explainDeepLink(_:)` distinguishes origin rejection, path mismatch, and
parameter conversion failure without executing authentication or navigation.
Catalog entries expose stable IDs, declaration namespaces, feature paths, and
parameter schemas. Parameter purity uses the actual metatype, so a custom type
that shadows a standard name is never executed by read-only analysis. Feature
routes retain their child declaration's origin when rendered; parent direct
routes retain the parent's origin. `RouterInspectorDeepLinkView(store:)` previews a redacted
structural diff with the pure reducer and keeps execution as a separate button;
execution resolves the URL and enters the normal store policy queue.

## Bounded navigation history

Attach `RouterHistory` only where app-owned back/forward and named checkpoints
are useful. It records stack paths, tab/split selection, and navigation inside
scenes that still exist. Moves use exact plans and normal policies, advance the
cursor only after an applied or unchanged result, and discard forward entries
after a successful branch. They preserve badges and presentations, reject path
changes beneath an active presentation, and never open or close a scene. Call
`reset(sessionKey:)` at an app-defined account or document boundary. History
observes commits synchronously, distinguishes deferred moves from rejection,
and invalidates suspended or deferred moves when the session resets or history
stops. Multiple active histories attached to the same Store synchronize their
cursors from successful history-originated commits while retaining independent
capacities, checkpoints, and session keys. An optional partial-restoration
validator is shared with snapshot repair.

## Result-bearing presentation

```swift skip doc-fragment
@Router
enum AppRoute {
    @PresentationResult(Bool.self)
    case settings
    // destination...
}

let request = AppRoute.Presentation.settings
switch await router.present(request) {
case .value(let saved): print(saved)
case .dismissed: break
case .cancelled: break
case .rejected(let reason): print(reason)
}

// Inside the presented destination:
try await router.finishPresentation(request, returning: true)
```

The generated request checks the result type at both call sites. The exact
presentation UUID and one completion request own the pending value, so a stale
completion or caller cancellation cannot dismiss a replacement presentation.
Cancellation remains attached while a deferred presentation is resumed, so a
late non-cooperative policy return cannot commit it. Interactive dismissal,
caller cancellation, route mismatch, result mismatch, and policy rejection
remain distinct outcomes. Sheets, covers, and popovers share snapshot-safe
detent, drag-indicator, compact-adaptation, and interactive-dismiss options.

## Scenes, system entry points, and existing apps

Use `@Scene(.window)` or `@Scene(.immersiveSpace)` on parameterless router
cases and install `RouterSceneDriver` once beside matching SwiftUI scene
declarations. A regular window uses `WindowGroup(id:for: UUID.self)` so each
`RouterWindow.id` opens and dismisses one exact native window instance. App
scene content attaches `routerWindowLifecycle(_:store:)` or
`routerImmersiveSpaceLifecycle(_:store:)` so interactive system dismissal
updates the same store and a policy rejection restores the native scene. A
queued immersive disappearance is tied to the exact native scene lifetime, so
it cannot close a replacement—even when the replacement reuses the same scene
identifier. App
Intents and Handoff render or consume the same canonical URL
contract through `RouterOpenURLIntentBuilder`, `routerHandoff`, and
`continueRouterHandoff`; Handoff intentionally accepts only HTTP(S) universal
links. Existing UIKit and AppKit applications can host the same store with
`RouterUIKitBridge` or `RouterAppKitBridge` without creating a second stack.
`RouterShortcutCatalog` shares stable route identifiers with app-owned App
Intents, while localized phrases and concrete shortcut declarations stay in
the application target. `RouterObservability` provides payload-free OSLog and
app-metrics hooks without collecting or transmitting analytics itself.

On visionOS, declare `RouterImmersiveSpaceScene(id:store:)` beside the driver
to carry each native open's identity into its lifecycle callbacks. A matching
restoration appearance can recover a committed failure repair with a new
revision and new scope authority. Existing id-only scenes keep their original
behavior and cannot revive an expired scene from an unattributed callback.
Declare wrapper IDs stably in the app's scene graph, with one declaration per
Store/ID. The originating system-close deferral can follow that same attributed
restoration; default resume still rejects unrelated state changes.

Each open window and immersive space owns an independent recursive node inside
the same application state. The macro-generated `AppRoute.Scene` catalog
provides typed window or immersive requests; `RouterWindowHost` and
`RouterImmersiveSpaceHost` render the exact scene-local history.
Applications with manual `RouterSceneRoute` conformances can pass a throwing
`RouterSceneCatalog` to `RouterSceneDriver`, rejecting empty or duplicate
identifiers and duplicate routes before native reconciliation starts.

## Choosing the right surface

| Need | 7.0 surface |
| --- | --- |
| Local stack and presentation | `@Router` + `RouterHost` |
| Tabs with independent branch history | `@Router` + `@TabItem` + `RouterTabHost` |
| Two- or three-column composition | `RouterSplitHost` / `RouterThreeColumnSplitHost` |
| External authority or policies | `RouterStore` + `RouterStoreConfiguration` |
| Idempotent or coalesced requests | atomic environment actions + `RouterRequestKey` |
| Externally approved transition | `RouterPolicyDecision.deferRequest` |
| Reactive read-only UI state | `@EnvironmentRouterState` |
| URL to complete target | `RouterLinkPipeline` + `RouterPlan` |
| Deferred authenticated URL | `RouterPendingLinkSlot` |
| Durable authenticated continuation | `RouterPendingLinkPersistenceDriver` |
| Versioned automatic restoration | `RouterRestorationDriver` + app-selected storage |
| Host-less transition assertions | `InnoRouterTesting.RouterTestStore` |
| Windows and immersive scenes | `@Scene` + `RouterSceneDriver` |
| App Intent or Handoff entry | `RouterOpenURLIntentBuilder` / `continueRouterHandoff` |
| Shortcut route catalog | `RouterShortcutCatalog` |
| Payload-safe local diagnostics | `RouterObservability` |
| UIKit or AppKit adoption | `RouterUIKitBridge` / `RouterAppKitBridge` |
| State tree, diff, and safe replay | `InnoRouterInspector` |

## Developer tooling

`RouterTestStore` executes the production reducer and policies and asserts the
ordered, correlated lifecycle, accepts transition context and exact plans, and
offers snapshot/restore assertions. `RouterInspectorRecorder` keeps a bounded,
searchable, payload-redacted timeline and supports JSON import/export,
step-through playback, session comparison, a native state tree, structural
diffs, bookmarks, correlated timing, arbitrary A/B comparison, rejection
breakpoints, and pure-reducer replay preview. The native view can import a JSON
snapshot or versioned diagnostic bundle with the platform file importer and
exports bundles containing framework/platform identity. An optional
`RouterInspectorScenarioController.routerScenario(store:)` adapter adds explicit
start, progress, stop, completeness, raw import, and raw export controls when
the app also imports `InnoRouterTesting`. Replay never mutates the live store;
scenario failures use payload-free categories instead of decoder or app error
descriptions, and a failed import cannot leave stale raw data exportable.
App-specific payload formatting remains an explicit opt-in. Imports default to
an 8 MiB encoded-data limit and 5,000 entries, checked before a full decode;
`RouterInspectorImportLimits` makes both bounds explicit when constructing the
recorder.

Inspector controls, accessibility labels, and generic status/failure messages
include English plus 15 translations: Korean, Japanese, Simplified and
Traditional Chinese, Spanish, French, German, Italian, Brazilian Portuguese,
Russian, Arabic, Hindi, Indonesian, Vietnamese, and Thai. Views follow the
SwiftUI locale, including changes while mounted; unsupported languages fall
back to English. Diagnostic identifiers and app-provided content remain
unchanged. See [Inspector localization](../Docs/inspector-localization.md) for
language overrides, semantic review, and validation boundaries.

`RouterActionSequence` stores each action with its transition context and
replays through `RouterTestStore`, preserving policy-visible provenance and
request metadata. Supply the original initial state and dependencies; replay
is sequential. These fixtures contain application payloads, unlike the default
redacted Inspector bundles. `RouterObservability.signposts` adds payload-free
transition intervals for Instruments, including cleanup when the adapter ends.

`RouterScenarioRecorder` synchronously captures bounded request, start,
cancellation, and terminal boundaries, including requests rejected before
reduction, so stopping immediately after a completed request cannot lose it.
Fixture format v9 stores the route schema, replay environment,
dependency/effect capabilities, initial revision, each request's relative
revision precondition and cancellation origin, logical
submit/wait/cancel/terminal controls, virtual-time advances, explicit deferral
decisions, and serializable execution semantics. History navigation therefore
replays through the production navigation-only merge with its original stale
state constraint even after queueing or repeated deferral rebases. Format v9
also carries transient display descriptors through the bounded fixture codec;
it never reconstructs live typed result authority. Navigation-only v8 fixtures
remain supported. Versions before v8 and unknown future versions are rejected
and must be recaptured because missing execution conditions cannot be inferred
safely.
Replay checks metadata and the complete initial
state before submitting its first request, remaps recorded deferral IDs to fresh
runtime IDs, and cancels and drains only its owned work before a failure or
cancellation returns. Resolve deferrals through the
recorder; missing controls, dropped data, and unfinished work make a fixture
incomplete instead of being guessed during replay.
Captured observations remain separate from
`RouterScenarioExpectation`; source generation is blocked until a developer
supplies every expected state, revision, and terminal result.
`RouterScenarioSourceGenerator.generateFiles` emits a Swift Testing source and
a separate reviewable JSON fixture using
`RouterScenarioRunner`, the real `RouterTestStore`, relative revisions, and an
app-provided policy factory. Overlapping busy/queue behavior, cancellation,
timeouts, and approvals replay from explicit controls rather than being
flattened into sequential sends. Default Inspector sharing contains only the
decision and declared route patterns; raw URLs and raw scenario fixtures require
separate explicit export actions.
