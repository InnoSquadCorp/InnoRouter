# InnoRouter

Macro-first, typed navigation for SwiftUI.

InnoRouter 6 turns one `@Router` enum into one navigation model:

- `RouterState<Route>` is the complete value-semantic source of truth.
- `RouterAction<Route>` is the only incremental request vocabulary.
- `RouterPlan<Route>` is an exact target used by links and restoration.
- `RouterStore<Route>` reduces, prepares policies, and commits atomically.
- `RouterHost`, `RouterTabHost`, and `RouterSplitHost` render native SwiftUI containers.

> **6.1.0:** Adds bounded snapshots, automatic partial restoration, explicit
> tab identity, and safer persistence while preserving the 6.0 public surface.
> Breaking changes target the next major release.

[한국어](README.ko.md) · [6.0 strategy](Docs/v6-functional-strategy.md) ·
[5.x migration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)

## Requirements

- Swift 6.3+
- `swift-tools-version: 6.3`
- iOS 18+, iPadOS 18+, Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+,
  visionOS 2+

## Installation

Add the package and its single runtime product:

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "6.1.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

`InnoRouterTesting` and `InnoRouterInspector` are optional developer products.
The granular 5.x runtime, macro, effect, scene, and spatial products are removed
from the 6.0 package contract.

## 30-second quick start

Start with a route enum and a macro-first host.

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case settings
    case detail(id: String)

    var destination: some View {
        switch self {
        case .settings:
            Text("Settings")
        case .detail(let id):
            Text("Detail \(id)")
        }
    }
}

struct HomeView: View {
    @EnvironmentRouter(AppRoute.self) private var router
    @EnvironmentRouterState(AppRoute.self) private var routerState

    var body: some View {
        Button("Open detail") {
            router.go(.detail(id: "42"))
        }
        .disabled(routerState.presentation != nil)
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) {
            HomeView()
        }
    }
}
```

The host owns the store by default. Create and inject a `RouterStore` only when
an application boundary needs restoration, policies, inspection, or direct
state observation.

## One runtime model

```swift skip doc-fragment
let store = AppRoute.makeRouterStore()

let outcome = await store.perform(.push(.detail(id: "42")))
let snapshot = try await store.snapshot(using: RouterSnapshotCodec(currentVersion: 1))
```

Each request follows `reduce → prepare → commit`. A policy rejection,
cancellation, stale preparation, or invalid action leaves committed state
unchanged. Successful requests assign one complete `RouterState` value and
increment the store revision once.

Use `goIfNeeded`, `backOrGo`, and `replaceTop` for atomic idempotent stack
changes. For bursty producers, attach a `RouterRequestKey` and choose
`keepFirst` or `replacePending`; unrelated requests retain FIFO order. A policy
may return `deferRequest` to release the execution lane while the app awaits an
external decision, then resume revision-safely or explicitly rebase on current
state.

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
overwritten. Stopping a driver invalidates queued workers and caller ownership;
a later activation cannot be modified by their delayed completion.

The byte limits above are application-selected examples. File storage rejects
oversized input while reading, and the codec independently bounds the encoded
envelope, decoded payload, and every migration result. Existing initializers
remain unbounded for source and behavior compatibility.

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

The explicit tab topology APIs below require **6.1.0 or later**.

The [complete tab restoration example](Examples/README.md#tab-restoration-610)
connects the catalog, driver, host, file persistence, and result handling.
The [restoration guide](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md)
explains tab identity, schema migration, and recovery boundaries.

Restoration is exact: it applies what the snapshot says. A snapshot written
before a tab existed therefore has no branch for it, and that tab stays
unreachable. To add the tabs the app renders now, state the topology:

```swift skip app-lifecycle-fragment
let topology = try RouterTabRestorationTopology(of: AppRoute.self)

try await store.restore(from: data, using: codec, tabTopology: topology)
```

A scope the snapshot carries keeps its path, presentation, and badge. A scope
it lacks is created empty — no route or badge is invented for it. A branch the
topology does not name is kept after the current scopes, so a later catalog can
still reach it; render such a store with
`RouterTabHost(store:catalog:allowingOrphanedBranches:)`. A selection the
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

Without `id:`, the case name remains the persisted scope identity. Add an
explicit ID before renaming a tab case to keep its saved branch reachable.
This stabilizes the tab scope only; changing a Codable route case used inside a
saved path still requires a snapshot migration. Effective IDs must be unique.

RouterTabHost(AppRoute.self, initial: .home)
```

The macro generates stable case-name scope identifiers, so localization or tab
reordering does not corrupt restored branch history. `@TabItem` can also define
a selected system image and native search-tab role.

`RouterSplitHost` owns independent sidebar and detail histories, while
`RouterThreeColumnSplitHost` adds an independent content column. Visibility and
preferred compact column live in `RouterSplitState` and reconcile through the
same system-origin transition pipeline. Custom column identifiers use the
throwing `RouterTwoColumnSplitLayout` and `RouterThreeColumnSplitLayout` values,
so duplicate, empty, or unavailable column topology is rejected before a host
is constructed.

Macro-generated tab metadata is the default. Advanced integrations that must
conform `RouterTabRoute` manually can first build a throwing `RouterTabCatalog`
and use the catalog-taking `RouterTabHost` initializer; duplicate identities,
scope IDs, root routes, initial tabs, and store topology become typed errors.

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

Each open window and immersive space owns an independent recursive node inside
the same application state. The macro-generated `AppRoute.Scene` catalog
provides typed window or immersive requests; `RouterWindowHost` and
`RouterImmersiveSpaceHost` render the exact scene-local history.
Applications with manual `RouterSceneRoute` conformances can pass a throwing
`RouterSceneCatalog` to `RouterSceneDriver`, rejecting empty or duplicate
identifiers and duplicate routes before native reconciliation starts.

## Choosing the right surface

| Need | 6.0 surface |
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
unchanged. See [Inspector localization](Docs/inspector-localization.md) for
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
Fixture format v7 stores the route schema, replay environment,
dependency/effect capabilities, initial revision, each request's relative
revision precondition and cancellation origin, logical
submit/wait/cancel/terminal controls, virtual-time advances, explicit deferral
decisions, and serializable execution semantics. History navigation therefore
replays through the production navigation-only merge with its original stale
state constraint even after queueing or repeated deferral rebases. Earlier
and unknown versions are rejected and must be recaptured because those
execution conditions cannot be inferred safely.
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

## OSS release and SemVer contract

The published 5.x line is source-stable within its major. InnoRouter 6.0.0 is a
deliberate breaking reset: old independent stores, intents, plans, coordinator
handoffs, and granular runtime products are no longer externally importable.
Pre-release tags such as `6.0.0-rc.1` use GitHub's `prerelease=true`; a bare
semantic tag is published only after package, docs, platform, API, and consumer
gates pass.

## Documentation

- [Functional strategy](Docs/v6-functional-strategy.md)
- [API convergence](Docs/v6-api-convergence-spike.md)
- [Functional specification](Docs/functional-expansion-spec.md)
- [Delivery plan](Docs/functional-expansion-technical-plan.md)
- [6.1.0 release checklist](Docs/6.1.0-release-checklist.md)
- [6.0.0 release checklist](Docs/6.0.0-release-checklist.md)
- [Migrating from 5.x](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Changelog](CHANGELOG.md)

## Quality gates

```bash
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

`--no-parallel` is required, not optional. `RouterSnapshotStorage` is a
synchronous protocol by design, so the restoration suites' storage doubles
hold a real thread inside `load()`/`save()` to keep an operation open. Swift
Testing runs suites concurrently in-process by default, and enough
simultaneously blocked doubles starve the cooperative pool: the restoration
tests then fail with 60s time-limit and `loadTimedOut` errors. The gates in
`scripts/principle-gates.sh` and `.github/workflows/coverage.yml` already pass
this flag.

Release validation additionally builds every supported Apple platform and Mac
Catalyst, verifies library-evolution interfaces for all three public products,
and builds a downstream consumer pinned to the candidate revision.

## License

MIT. See [LICENSE](LICENSE).
