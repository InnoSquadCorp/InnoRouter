# InnoRouter 6.0 Functional Strategy

- Document status: Draft; maintainer approval is not recorded
- Implementation state: Implemented
- Publication status: Published
- Published version: 6.0.0
- Published commit: f6abef8ee77677c48b32563aac2efaa82100b132
- Published date: 2026-09-16
- As of: 2026-09-18

## Decision

InnoRouter 6.0 is macro-first. `@Router` is the default product entry point,
and the generated `DestinationRoute` conformance unlocks one
`RouterStore<Route>`, one recursive `RouterState<Route>`, and one
`RouterAction<Route>` vocabulary.

The 5.x model of composing independent navigation, modal, flow, shell, split,
window, and spatial stores is not the 6.0 architecture. Those implementations
remain available in Git history only; they are absent from the working source
tree, package build graph, external product surface, and symbol surface.

## Product thesis

> A route declaration should produce one coherent navigation authority. Every
> accepted request commits one complete state value; every rejected request
> leaves that value unchanged and explains why.

## 6.0 cut

| Capability | 6.0 contract | State |
| --- | --- | --- |
| Macro-first setup | `@Router` plus `RouterHost`, `RouterTabHost`, or `RouterSplitHost` | Implemented |
| Single source of truth | Recursive stack/container/window/immersive `RouterState` | Implemented |
| One request vocabulary | Incremental `RouterAction`; exact-state `RouterPlan` | Implemented |
| Async policy | reduce, prepare, stale/cancel check, atomic commit | Implemented |
| Typed outcomes | applied, unchanged, or rejected with one transition ID | Implemented |
| Restoration | deterministic versioned snapshot, adjacent migrations, explicit recovery | Implemented |
| Macro-first reads | `@EnvironmentRouterState` read-only observation over the nearest scope | Implemented |
| Automatic restoration | opt-in driver over application-selected snapshot storage | Implemented |
| Result presentations | value, interactive dismissal, caller cancellation, policy rejection | Implemented |
| Deep links | one fail-closed URL-to-`RouterPlan` pipeline | Implemented |
| Deferred links | exact-plan resume with explicit replacement/cancellation semantics | Implemented |
| Test support | production reducer/policy `RouterTestStore` with exhaustive events | Implemented |
| Inspector | correlated timeline plus redacted import, playback, and comparison | Implemented |
| System diagnostics | payload-safe unified logging and app-owned metrics adapter | Implemented |
| Shortcut routes | stable typed IDs shared with app-owned App Intents | Implemented |
| Stable tab persistence | macro-generated case-name `RouterScopeID` | Implemented |
| Platform adaptation | explicit capability values plus correlated fallback events | Implemented |
| Host topology safety | throwing typed split layouts reject invalid raw topology | Implemented |
| Admission resilience | bounded FIFO requests, policy timeout, and bounded/expiring deferrals | Implemented |
| Advanced manual catalogs | throwing validated tab and scene catalogs | Implemented |
| Inspector import safety | byte and entry preflight before JSON decoding | Implemented |
| Platform interface contract | library-evolution interfaces checked for every platform floor, including Mac Catalyst | Implemented |
| Public convergence | three library products; legacy authorities and vocabularies outside the build graph | Implemented |

## Public product boundary

6.0 publishes only these selectable library products:

- `InnoRouter` — macros plus canonical runtime and SwiftUI hosts;
- `InnoRouterTesting` — `RouterTestStore` and exhaustivity controls;
- `InnoRouterInspector` — opt-in redacted developer UI and recording.

The former granular products are intentionally removed. `InnoRouter` is not a
collection of independently selected routing engines anymore.

## Invariants

1. `RouterStore.state` is the only mutable navigation authority for a route
   type at a host boundary.
2. A `RouterScope` is a stable read-only projection and action forwarder, never
   a child store.
3. Reducer evaluation is synchronous and value-semantic. No store state is
   borrowed across `await`.
4. Policies inspect an immutable transition candidate. A busy, stale,
   cancelled, or rejected transition cannot partially commit.
5. Presentations block stack progression in their scope until dismissal.
6. Restoration data describes state, not executable commands or business
   effects.
7. Default inspector records never retain or print route payloads.
8. Automatic restoration and diagnostics are opt-in adapters over the same
   store; neither selects storage, transmits analytics, or owns business state.
9. Untrusted or externally delayed work is bounded: queued requests, policy
   preparation, unresolved deferrals, and Inspector imports cannot grow or
   suspend indefinitely without an explicit application configuration.
10. Macro-generated catalogs remain the default. Advanced manual tab and scene
    catalogs enter native hosts only after throwing structural validation.
11. Caller cancellation wins the policy race even when policy work ignores
    cancellation or has a longer configured timeout.

## Breaking removals

The 6.0 external surface no longer exposes `NavigationStore`, `ModalStore`,
`FlowStore`, `AppShellStore`, `AdaptiveSplitStore`, `SceneStore`, their intent
families, `NavigationPlan`, `FlowPlan`, coordinator callback lifecycles, or the
separate effects product. Their replacements are listed in the migration guide.

## Non-goals

- business state, authentication implementation, networking, or analytics;
- replaying application effects from the inspector;
- modal queues encoded as simultaneously visible state;
- UIKit/AppKit controller ownership;
- a deployment-floor increase without a concrete API requirement.

## Release record

6.0.0 was published on 2026-09-16 after its package, macro, public-API,
documentation, platform, and exact downstream-consumer gates passed on the
release toolchain. The immutable release evidence is recorded in
`6.0.0-release-checklist.md` and `6.0.0-publication-execution.ko.md`.

This strategy document remains Draft until maintainer approval is recorded;
publication and implementation progress do not self-approve the product
decision. Post-release changes follow SemVer and the same release gates.
