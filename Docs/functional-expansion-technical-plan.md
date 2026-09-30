# InnoRouter 6.0 Delivery Plan with 6.1–6.3 Capability Sets

- Status: Implemented local candidate
- As of: 2026-09-05
- Strategy: `v6-functional-strategy.md`

The implementation status below covers Stages 1–12 only. The next six
user-requested capabilities are planned separately and are not implemented:
[Korean feature specification](6.0.0-next-capabilities-spec.ko.md) and
[sequential technical plan](6.0.0-next-capabilities-plan.ko.md), both Draft.

## Delivery sequence

### Stage 1 — canonical state and execution — complete locally

- recursive `RouterState` and stable scope paths;
- one pure `RouterReducer` and `RouterAction` language;
- async policies with busy, cancellation, and stale-revision protection;
- exactly one observable assignment per accepted transition;
- correlated outcomes and events.

### Stage 2 — macro-first native hosts — complete locally

- `DestinationRoute.makeRouterStore` generated indirectly by `@Router`;
- `RouterHost`, `RouterTabHost`, and `RouterSplitHost` own one store;
- tabs use branches inside the same state tree rather than per-tab stores;
- mixed `@TabItem` roots and associated-value destinations are supported;
- macro-generated tab scope IDs are stable across localization and ordering.

### Stage 3 — links, persistence, and presentations — complete locally

- one `RouterLinkPipeline` outputs exact `RouterPlan` values;
- macro-generated deep-link resolution uses that canonical pipeline;
- deterministic versioned snapshot envelopes and ordered migrations;
- explicit fail or fallback recovery with provenance;
- result-bearing presentation, interactive dismissal, and caller cancellation.

### Stage 4 — developer tooling — complete locally

- `RouterTestStore` runs the production reducer and policies;
- exhaustive ordered event assertions and policy failure injection;
- bounded inspector timeline with shared transition IDs;
- structural state trees, field diffs, search, JSON export, and route payload
  redaction;
- safe pure-reducer replay preview that never mutates the live store;
- inspector remains an opt-in product.

### Stage 5 — public convergence and migration — complete locally

- publish only `InnoRouter`, `InnoRouterTesting`, and `InnoRouterInspector` as
  selectable library products;
- remove 5.x engines and regression sources from the working tree while
  retaining migration evidence in Git history;
- generate public-API baselines from the modules re-exported by the umbrella;
- document the 5.x-to-6.0 replacement matrix;
- update quick-start and release notes to macro-first terminology.

### Stage 6 — release verification — complete locally

Required before tagging:

1. full Swift package tests;
2. macro expansion and runtime behavior suites;
3. v6 public API and banned-symbol checks;
4. documentation consistency and compile blocks;
5. supported-platform builds;
6. downstream consumer build pinned to the release revision;
7. diff and repository scope review.

The complete local gate, including all supported-platform compile probes, passes
on Xcode 27.0 / Swift 6.4. The pinned Xcode 26.6 / Swift 6.3 CI run, exact-tag
downstream consumer run, and maintainer diff review remain release-time gates;
see `6.0.0-release-checklist.md`.

## Verification model

- reducer tests prove value invariants;
- store tests prove async atomicity and exact presentation lifetimes;
- macro tests prove generated conformance and stable identifiers;
- host tests prove scope sharing;
- snapshot fixtures prove deterministic migration;
- inspector tests prove correlation and redaction;
- public symbol graphs prove retired 5.x APIs cannot be imported externally.

### Stage 7 — planned 6.1 capability set — complete before first tag

- separate generated tab identities from ordinary route cases;
- serialize requests FIFO and reconcile rejected system bindings;
- add atomic plan DSL, presentation options, transition provenance, and
  semantic animation;
- generate typed presentation result requests;
- generate `@Scene` catalogs and reconcile them with native scene actions;
- bridge App Intent URLs and universal-link Handoff through one plan pipeline;
- add UIKit/AppKit hosting bridges over the same canonical store;
- expand Inspector tree, diff, export, search, and replay tooling.

### Stage 8 — planned 6.2 capability set — complete before first tag

- add `@EnvironmentRouterState` as the read-only macro-first counterpart to
  `@EnvironmentRouter`;
- resume exact pending link plans with explicit slot replacement,
  cancellation, rejection retention, and consumption policies;
- add an opt-in restoration driver over application-selected storage with
  coalesced commits and scene-phase flushing;
- import, step through, and compare payload-redacted Inspector sessions;
- extend `RouterTestStore` with transition context, exact plans, snapshots,
  restoration, unchanged events, and state assertions.

### Stage 9 — best-effort 6.3 capability set — complete before first tag

- emit payload-free diagnostic values to unified logging or app-owned metrics
  adapters without remote collection;
- share stable typed route IDs through `RouterShortcutCatalog` while leaving
  concrete App Intent phrases, titles, policies, and providers app-owned.

### Stage 10 — post-6.3 functional hardening — complete before first tag

The final implementation sequence was completed in dependency order:

1. move every window and immersive space to its own recursive canonical node,
   add domain-aware scopes, generate typed scene requests, and add scene hosts;
2. model complete two- and three-column split topology, visibility, compact
   preference, and independent native column histories;
3. add atomic idempotent stack actions plus keyed keep-first and
   replace-pending request coalescing;
4. generalize policy deferral with explicit resolution, unchanged-state or
   rebased resume, lane release, and result-bearing presentation continuity;
5. add selected presentation detents, interaction and corner-radius options,
   selected tab images, and native search-tab roles;
6. persist the exact pending link through versioned app-selected storage with
   generation ownership and convergent saving;
7. expand Inspector with bookmarks, correlated timing, arbitrary A/B state
   comparison, rejection breakpoints, and native JSON import.
8. publish an explicit per-platform capability contract, correlate every native
   fallback, replace raw split-host topology with validated layouts, and run
   the contract on each supported simulator family.
9. bound the serialized request queue, add policy timeouts, and bound or expire
   unresolved policy deferrals with explicit overflow outcomes;
10. preflight Inspector imports by encoded byte count and top-level entry count
    before decoding or mutating a session;
11. add throwing validated tab and scene catalogs for advanced manual route
    conformances while retaining macro-generated catalogs as the default;
12. compile and verify library-evolution interfaces for the three public
    products on every platform floor, including Mac Catalyst.

### Stage 11 — release diagnosis and reproducibility — complete before first tag

- expose one runtime release identity for support metadata;
- compile-check adjacent snapshot migrations with typed Codable payloads;
- add payload-free Instruments intervals without collecting route values;
- export deterministic, versioned, redacted Inspector support bundles;
- serialize and replay the complete production action vocabulary as versioned
  deterministic `RouterTestStore` fixtures.

### Stage 12 — diagnostic workflow and boundary correctness — complete before first tag

- reject nonpositive snapshot versions and migration definitions beyond the
  current schema, including integer extremes without arithmetic overflow;
- preserve every action's transition context in serialized regression steps;
- reopen diagnostic bundles through the Recorder and native Inspector, enforce
  format/byte/entry validation, and preserve the timeline on import failure;
- recognize escaped JSON envelope keys and reject duplicates before entry
  decoding, normalize bookmarks, and clear stale timing when replacing sessions;
- test signpost correlation, every terminal outcome, repeated starts, and
  adapter teardown through the same interval owner used by Instruments;
- verify these public workflows from the independent macro-first consumer.

## Deferred after the first 6.0.0 tag

- built-in cloud synchronization or framework-selected storage locations;
- concrete application-owned App Intent and shortcut declarations;
- effect execution or live-store mutation during Inspector replay;
- production analytics collection.
