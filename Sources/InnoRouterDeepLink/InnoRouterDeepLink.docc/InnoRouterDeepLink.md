# InnoRouterDeepLink

Fail-closed URL matching and complete-plan routing for InnoRouter 6.

## Overview

`@Router` plus `@DeepLink` generates typed URL resolution from literal scheme
and host allowlists. Manual integrations use `DeepLinkMatcher`,
`DeepLinkOriginPolicy`, and `RouterLinkPipeline<Route>`.

`RouterLinkPipeline` maps each admitted URL to a complete `RouterPlan`, the
same exact-state value used by transactions and restoration. Its authentication
policy scans stack routes, presentations, container branches, windows, and the
immersive space. A gated decision retains the exact pending plan.
The umbrella runtime adds `RouterPendingLinkSlot` and `RouterStore.resume` so
applications can explicitly replace, cancel, or continue that plan after
authentication without parsing the URL again.

## Decision flow

1. Reject disallowed origins and input-limit violations.
2. Match a route or a complete plan.
3. Build the exact target `RouterPlan`.
4. Return the plan, retain it as pending, or report unhandled input.
5. Resume a pending plan explicitly after authentication when needed.
6. Apply an accepted plan through `RouterStore.perform(.apply(plan))`.

URL parsing never mutates navigation state and never performs authentication,
networking, analytics, or persistence.

Macro routers can opt into `inspectorCatalog: true`. The generated
`DeepLinkRouteCatalog` uses the resolver's specificity order and publishes only
case names, patterns, and parameter type schemas. `explainDeepLink(_:)` reports
origin admission, ordered pattern attempts, and conversion failure; it does
not call authentication, application policies, or the router store.
Framework-owned conversion is determined from the resolved parameter metatype,
not its spelled name. A custom type that shadows `UUID`, `String`, or another
standard name therefore remains application-owned and is not invoked by
read-only analysis. Composed feature routes also retain their declaring
router's origin policy when rendering URLs; parent direct routes do not inherit
child origins.
