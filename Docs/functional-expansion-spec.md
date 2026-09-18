# InnoRouter 6.0 Functional Specification with 6.1–6.3 Capability Sets

- Document status: Draft; maintainer approval is not recorded
- Implementation status: FR6-001–053 published in 6.0.0
- Revision: 1.5
- Target: published 6.0.0 contract plus compatible 6.0.x fixes
- Updated: 2026-09-18

The contract below defines FR6-001–035. Six additional capability groups extend
the identifiers with FR6-036–053 and AC6-031–048 in the
[Korean addendum](6.0.0-next-capabilities-spec.ko.md). Those capabilities were
implemented before the first 6.0.0 tag and published with it. Both documents
remain Draft as review artifacts because named approval is still unrecorded;
that lifecycle status is separate from implementation and publication.

## Product contract

An `@Router` declaration unlocks one `RouterStore<Route>` whose complete state
is a `RouterState<Route>`. All incremental changes use `RouterAction<Route>`;
all exact destinations use `RouterPlan<Route>`. Native hosts are views over
that authority, not owners of parallel stores.

## Requirements

### FR6-001 Macro-first declaration

`@Router` shall synthesize destination conformance and the metadata required by
the applicable host. `@TabItem` shall mark only tab roots; unmarked cases shall
remain usable as ordinary destinations.

### FR6-002 Single recursive state

`RouterState` shall represent stack paths, one presentation per stack, nested
tab/split/custom branches, selection, normalized badges, regular windows, and
at most one immersive space in one validated value.

### FR6-003 One action and one plan

`RouterAction` shall be the sole public incremental request language.
`RouterPlan` shall wrap one exact target state and be shared by deep links,
transactions, and restoration.

### FR6-004 Atomic async execution

`RouterStore` shall synchronously reduce a candidate, await policies in order,
check cancellation and revision staleness, then make at most one observable
state assignment. Busy, rejected, cancelled, stale, and invalid requests shall
not partially commit.

### FR6-005 Stable scopes

A child `RouterScope` shall retain stable identity, expose only a read-only node
projection, and forward scoped actions to the owning store. It shall never be a
second mutable authority.

### FR6-006 Result-bearing presentation

An awaited presentation shall resolve exactly once as a typed value, user
dismissal, caller or parent cancellation, or policy rejection. Completion shall
be bound to the exact presentation identifier and reject missing or mismatched
sessions.

### FR6-007 Versioned restoration

`RouterSnapshotCodec` shall use a deterministic, versioned envelope, require an
adjacent migration chain within the current schema, reject nonpositive, future,
or missing versions distinctly, and validate decoded state. Migration definition
validation shall not overflow for any integer input. Recovery shall be explicit and report whether the
result was restored or supplied by an app fallback.

### FR6-008 Canonical link pipeline

`RouterLinkPipeline` shall fail closed on origin and input-limit violations,
map an admitted URL to a complete `RouterPlan`, inspect the whole target tree
for authentication, and retain the exact pending plan.

### FR6-009 Native hosts

`RouterHost`, `RouterTabHost`, and `RouterSplitHost` shall render native SwiftUI
containers from one store. Tab branches shall preserve independent histories
inside the same state tree and use macro-generated stable case identifiers.

### FR6-010 Testing

`RouterTestStore` shall run production reduction and policies, buffer the exact
correlated lifecycle synchronously, and support strict or relaxed exhaustivity.

### FR6-011 Inspector

The optional inspector shall record a bounded ordered timeline with transition
correlation and structural before/after summaries. Default formatting shall not
retain route payloads or policy messages. Custom payload formatting shall be an
explicit application opt-in.

### FR6-012 Breaking public convergence

The package shall expose only `InnoRouter`, `InnoRouterTesting`, and
`InnoRouterInspector` as selectable library products. The 5.x independent
stores, intent/plan families, coordinator lifecycle API, and granular runtime
libraries shall not appear in the external 6.0 symbol or dependency surface.

### FR6-013 Stable tab identity

Tab-only APIs shall accept a generated nested `Tab` identity, never the full
route enum. Ordinary push and presentation routes therefore cannot enter tab
selection or badge APIs.

### FR6-014 Scheduling and transition context

Requests shall serialize FIFO by default, with busy rejection available only
as an explicit policy. Every transition shall carry application, system, link,
restoration, App Intent, Handoff, or Inspector provenance plus optional semantic
animation metadata.

### FR6-015 Atomic plan DSL and native presentation options

`RouterPlanBuilder` shall derive one validated exact target from ordered scoped
and global steps before dispatch. Presentation state shall persist sheet,
cover, popover, detent, drag-indicator, compact-adaptation, and interactive
dismiss semantics.

### FR6-016 Compile-time presentation result contracts

`@PresentationResult(Value.self)` shall generate a typed request for
parameterless and associated-value route cases. The same request shall type
check both presentation and completion and reject an unrelated active route.

### FR6-017 Scene and system integration

`@Scene` shall generate a partial window/immersive catalog on `@Router`.
`RouterSceneDriver` shall reconcile committed state through native SwiftUI scene
actions, preserving each regular window's UUID through value-based
`WindowGroup` dispatch. Scene lifecycle modifiers shall feed interactive native
dismissal back through the system-origin transition pipeline and restore the
native scene if a policy rejects that dismissal. App Intent and Handoff bridges
shall use the canonical bidirectional URL and whole-plan pipeline; Handoff
publication shall accept universal-link origins only.

### FR6-018 Incremental UIKit and AppKit adoption

Platform hosting bridges shall embed `RouterHost` around the exact application-
owned `RouterStore`, preserve native controller lifecycle, and never mirror
navigation into a second authority.

### FR6-019 Inspector state tools and legacy isolation

The Inspector shall add search, structural state trees, field diffs, JSON
export, and pure-reducer replay that cannot mutate the live store. Retired 5.x
sources shall remain available as archive evidence outside the package build
graph.

### FR6-020 Macro-first read projection

`@EnvironmentRouterState` shall resolve the same nearest typed authority as
`@EnvironmentRouter` and expose an observation-aware, read-only projection.
Reading state shall not create a second mutable owner or require direct store
injection into ordinary destination views.

### FR6-021 Deferred-link continuation

An authentication-gated link shall be resumable from its retained exact plan
without re-parsing the URL. One optional pending slot shall make replacement,
cancellation, rejection retention, and consumption behavior explicit.

### FR6-022 Opt-in automatic restoration

An application-selected snapshot storage protocol and driver shall load and
save outside the main actor, restore through normal policies, coalesce writes,
and flush on scene deactivation. The driver shall not add implicit storage,
cloud synchronization, or a parallel navigation authority.

### FR6-023 Imported developer sessions and test parity

Inspector exports shall support bounded import, pure step-through playback, and
payload-redacted session comparison. `RouterTestStore` shall accept transition
context and plans and expose production snapshot/restoration assertions.

### FR6-024 Optional system observability and shortcut catalog

Applications may opt into payload-free unified logging or app-owned metrics
events and share stable typed route identifiers with concrete App Intents.
InnoRouter shall not collect analytics or generate localized application-owned
intent/provider declarations.

### FR6-025 Scene-local canonical navigation

Every regular window and immersive space shall own an independent recursive
`RouterNode` inside the application `RouterState`. `RouterScopePath` shall name
application, window, and immersive domains without creating another authority.
`@Scene` shall generate typed window or immersive requests, and dedicated scene
hosts shall render the exact scene-local stack and presentation state.

### FR6-026 Complete native split state

Split containers shall persist two- or three-column topology, column
visibility, and preferred compact column in validated canonical state. Each
column shall retain an independent stack scope, and native bindings shall
dispatch through the normal system-origin pipeline.

### FR6-027 Idempotent and coalesced requests

The action vocabulary shall provide atomic push-if-needed, back-or-push, and
replace-top operations. Callers may attach a semantic request key and select
FIFO, keep-first, or replace-pending queue behavior. Coalescing shall preserve
unrelated request order and return correlated typed rejection reasons.

### FR6-028 General policy deferral

Any policy may defer a transition without occupying the serialized execution
lane. The store shall expose payload-safe deferral metadata and require an
explicit allow, reject, or cancel resolution. Resume shall require the original
revision by default, with an explicit rebase-on-current-state alternative.
Result-bearing presentation continuations shall remain live through deferral
and resolve exactly once.

### FR6-029 Native presentation and tab parity

Presentation state shall additionally retain selected detent, background and
content interaction, and corner radius, with native selected-detent updates
routed through canonical state. `@TabItem` shall support selected system images
and native search role while keeping generated tab identity stable.

### FR6-030 Durable pending-link continuation

`PendingRouterLink` shall be codable when its route is codable. An opt-in,
versioned persistence driver over application-selected storage shall atomically
restore, save, cancel, submit, and resume the single pending slot. A slow load
shall never overwrite a newer in-memory submission, and saving shall converge
on the latest slot generation.

### FR6-031 Inspector investigation workflow

Inspector sessions shall preserve bookmarks, correlated elapsed and transition
duration metadata, arbitrary A/B state comparisons, and an optional pause on
terminal rejection. The native inspector shall import JSON snapshots through
the platform file importer without gaining any live-store mutation capability.

### FR6-032 Explicit platform adaptation and safe host topology

`RouterPlatformCapabilities` shall declare the native routing features rendered
by each supported Apple platform. A host that cannot render a requested style,
option, or badge visual shall make the effective behavior deterministic and
emit one correlated, payload-safe adaptation event. Custom split topology shall
enter hosts only through throwing validated layout values. Retired 5.x source
shall remain in Git history rather than the working source graph.

### FR6-033 Bounded request and import resilience

The serialized request lane shall have a configurable pending bound with
explicit reject-newest or discard-oldest overflow behavior. Policy preparation
may have a timeout, but caller cancellation shall win without waiting for a
non-cooperative policy or its timeout. Unresolved deferrals shall have a
configurable capacity,
overflow strategy, and optional TTL, and every eviction or expiry shall finish
awaiting presentation work exactly once. Inspector imports shall reject an
oversized byte envelope or excessive entry count before full JSON decoding or
timeline mutation.

### FR6-034 Validated advanced catalogs and platform interfaces

`@Router` remains the primary producer of tab and scene catalogs. Applications
that cannot use the macro shall have throwing `RouterTabCatalog` and
`RouterSceneCatalog` values so malformed manual metadata never reaches a host
precondition. CI shall build library-evolution interfaces for all three public
products at every Apple platform floor, including Mac Catalyst, and reject
legacy 5.x symbol leakage.

### FR6-035 Release diagnostics and reproducible regressions

The runtime shall expose its release identity, typed adjacent Codable snapshot
migrations, and payload-free Instruments signposts whose intervals close exactly
once on outcomes, repeated starts, and adapter teardown. Inspector support bundles
shall encode redacted sessions deterministically, reject unsupported formats,
and reopen through bounded, atomic Recorder and native UI imports. Testing shall
preserve complete production actions and each action's transition context in a
versioned deterministic fixture that replays only through `RouterTestStore`.
Sequential replay requires caller-supplied initial state and dependencies and
does not claim to reproduce concurrent request timing.

## Acceptance criteria

| ID | Evidence |
| --- | --- |
| AC6-001 | Macro expansion and runtime tests prove generated conformance, mixed tab/destination cases, and stable scope IDs. |
| AC6-002 | Reducer tests prove every node invariant and rejected-action immutability. |
| AC6-003 | Store tests prove one revision per commit plus busy, policy rejection, cancellation, and stale protection. |
| AC6-004 | Presentation tests prove value, interactive dismiss, policy rejection, cancellation during prepare, and wrong-result-type behavior. |
| AC6-005 | Snapshot fixtures prove deterministic round trip, bounded adjacent migration definitions including integer extremes, nonpositive/future/gap errors, validation, and explicit recovery provenance. |
| AC6-006 | Link tests prove fail-closed admission, complete-plan output, whole-tree authentication, and pending replay. |
| AC6-007 | Host tests prove tab branches preserve sibling state and split descendants project from the same canonical store. |
| AC6-008 | Inspector tests prove correlation, capacity, export, and default redaction. |
| AC6-009 | Public product and symbol-graph gates reject reintroduction of retired 5.x surfaces. |
| AC6-010 | Full package, macro, documentation, platform, and downstream consumer gates pass on the release toolchain before tagging. |
| AC6-011 | Typed presentation macro tests prove parameterless and associated-value requests plus wrong-route rejection. |
| AC6-012 | Scene, App Intent, Handoff, and platform bridge tests prove one canonical plan/store path. |
| AC6-013 | Inspector tests prove payload-redacted trees/diffs/export and non-mutating replay. |
| AC6-014 | The public product build compiles only the canonical source graph; retired engines remain available in Git history and are absent from the checkout. |
| AC6-015 | Environment-state tests prove read-only stack, presentation, container, window, and immersive projections over the same scope. |
| AC6-016 | Link tests prove exact pending resume, explicit replacement/cancellation, and default retention after policy rejection. |
| AC6-017 | Restoration tests prove file round trip, coalesced commit saving, normal-policy restore provenance, and non-mutating removal; platform builds compile scene-phase integration. |
| AC6-018 | Inspector and Testing tests prove import/step/compare and context/plan/snapshot parity without live-store replay mutation. |
| AC6-019 | System tests prove payload-free diagnostics and stable shortcut IDs while concrete App Intent declarations remain app-owned. |
| AC6-020 | State, scope, macro, and host tests prove independent window/immersive histories plus typed scene requests over one store. |
| AC6-021 | Split tests prove validated two- and three-column topology, independent histories, and native visibility/compact-column reconciliation. |
| AC6-022 | Queue and reducer tests prove idempotent actions, keep-first and replace-pending behavior, unrelated FIFO order, and typed supersession. |
| AC6-023 | Store and presentation tests prove lane release, unchanged-state and rebase resume, rejection/cancellation, and deferred typed-result completion. |
| AC6-024 | Presentation, host, and macro tests prove selected-detent binding, interaction options, selected tab images, and search role. |
| AC6-025 | Pending-link persistence tests prove deterministic round trip, atomic removal, generation ownership, malformed-data failure, and canonical resume. |
| AC6-026 | Inspector tests prove bookmarks, correlated timing, rejection breakpoints, arbitrary state comparison, backward-compatible snapshots, and file import wiring. |
| AC6-027 | Capability tests execute on every supported platform family, including Mac Catalyst, unsupported visuals emit redacted adaptation events, and invalid split layouts throw before host construction. |
| AC6-028 | Store tests prove bounded queue overflow strategies, policy timeout, cancellation precedence, deferral capacity/eviction/TTL, exact waiter completion, and non-error deferral diagnostics; Inspector tests prove byte and entry preflight. |
| AC6-029 | Manual catalog tests prove typed tab/scene validation failures, and the platform matrix verifies all three public library-evolution interfaces at each declared deployment floor including Mac Catalyst. |
| AC6-030 | Snapshot, system, Inspector, and Testing tests prove typed migrations, exact signpost interval ownership, deterministic versioned support bundle import/export, and per-action context round trips including policy rejection through the production test store. |

## Non-functional requirements

- Public mutable state is `@MainActor` isolated.
- Public value contracts are `Sendable`; routes remain `Hashable & Sendable`.
- Reducer behavior is deterministic and side-effect free.
- No storage, authentication, networking, analytics, or business effects run implicitly.
- No mutable router state is held across suspension.
- Default diagnostics are payload-safe.
- Platform floors remain iOS/iPadOS 18, macOS 15, tvOS 18, watchOS 11, and visionOS 2.

## Out of scope for the first 6.0.0 tag

- built-in cloud synchronization or a framework-selected storage location;
- executing app effects or mutating a live store during inspector replay;
- generating an application-owned concrete `AppIntent` or
  `AppShortcutsProvider` declaration;
- production analytics collection.

## Traceability

| Requirement | Primary implementation | Primary evidence |
| --- | --- | --- |
| FR6-001, FR6-009 | `@Router`, `RouterTabHost`, `RouterSplitHost` | macro behavior and host tests |
| FR6-002, FR6-003 | `RouterState`, `RouterAction`, `RouterPlan`, `RouterReducer` | `RouterStateTests` |
| FR6-004, FR6-005 | `RouterStore`, `RouterScope` | `RouterStoreTests` |
| FR6-006 | presentation waiter in `RouterStore` | presentation lifecycle tests |
| FR6-007 | `RouterSnapshotCodec` | `RouterSnapshotTests` |
| FR6-008 | `RouterLinkPipeline` | `RouterLinkPipelineTests` |
| FR6-010 | `RouterTestStore` | `RouterTestStoreTests` |
| FR6-011 | `RouterInspectorRecorder` | `RouterInspectorTests` |
| FR6-012 | `Package.swift`, API baselines and gates | product/API checks |
| FR6-013, FR6-016 | `@TabItem`, `@PresentationResult` | macro snapshot and behavior tests |
| FR6-014, FR6-015 | `RouterStore`, `RouterTransitionContext`, `RouterPlanBuilder` | store and reducer tests |
| FR6-017 | `RouterSceneDriver`, `InnoRouterSystem` | scene behavior and system integration tests |
| FR6-018 | `PlatformHostingAdapters` | platform adapter tests and platform builds |
| FR6-019 | `InnoRouterInspector`, Git history boundary | inspector tests and package graph review |
| FR6-020 | `EnvironmentRouterState`, `RouterStateReader` | environment-state tests and consumer smoke |
| FR6-021 | `RouterPendingLinkSlot`, `RouterStore.resume` | link pipeline tests |
| FR6-022 | `RouterRestorationDriver`, `RouterSnapshotStorage` | restoration driver tests |
| FR6-023 | `RouterInspectorPlayback`, `RouterTestStore` | Inspector and Testing tests |
| FR6-024 | `RouterObservability`, `RouterShortcutCatalog` | system integration tests |
| FR6-025 | `RouterScopeDomain`, `RouterWindowHost`, `RouterImmersiveSpaceHost`, generated `Route.Scene` | state, scene host, and macro tests |
| FR6-026 | `RouterSplitState`, `RouterSplitHost`, `RouterThreeColumnSplitHost` | reducer and host tests |
| FR6-027 | `RouterRequestKey`, request coalescing, idempotent actions | reducer and scheduling tests |
| FR6-028 | deferred request registry in `RouterStore` | store and presentation lifecycle tests |
| FR6-029 | `RouterPresentationOptions`, `RouterTabRole`, `@TabItem` | presentation, host, and macro tests |
| FR6-030 | `RouterPendingLinkPersistenceDriver`, `RouterPendingLinkStorage` | pending-link persistence tests |
| FR6-031 | `InnoRouterInspector` bookmarks, timing, comparison, and import | Inspector tests and platform builds |
| FR6-032 | `RouterPlatformCapabilities`, `RouterPlatformAdaptation`, typed split layouts | platform runtime, Inspector, and split-layout tests |
| FR6-033 | `RouterStoreConfiguration`, deferral registry, `RouterInspectorImportLimits` | scheduling, presentation, observability, and Inspector import tests |
| FR6-034 | `RouterTabCatalog`, `RouterSceneCatalog`, platform interface baseline | host catalog tests and per-platform interface gate |
| FR6-035 | `InnoRouterVersion`, typed snapshot migration, `RouterObservability.signposts`, diagnostic bundles, `RouterActionSequence` | snapshot, system, Inspector, and Testing tests |

## Release record

The FR6-001–053 implementation shipped in 6.0.0 on 2026-09-16. The release
checklist records the exact tag, release-toolchain gates, downstream resolution,
and publication result. Future compatible fixes require a new immutable SemVer
tag and the same release gates. This document's Draft review state remains
unchanged until a maintainer approval and date are recorded.
