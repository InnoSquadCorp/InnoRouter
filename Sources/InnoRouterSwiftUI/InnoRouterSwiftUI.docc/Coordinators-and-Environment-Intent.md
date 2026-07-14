# Coordinators and environment intent

@Metadata {
  @PageKind(article)
}

Coordinators in InnoRouter are SwiftUI-adapted reference authorities, not UIKit-era imperative routers.

## Coordinator role

`Coordinator` exists for cases where view intent should flow through a policy object before it reaches the store.

A coordinator:

- receives `NavigationIntent`
- decides whether to forward, rewrite, or replace commands
- maps routes to destinations
- stays observable for SwiftUI

`Coordinator` remains `AnyObject` by design because it is a shared authority object, not ephemeral view state.

## Environment intent

`EnvironmentNavigationIntent` and `EnvironmentModalIntent` are the primary view-facing APIs.

This keeps view code declarative:

- child views do not need a direct store reference
- fail-fast behavior catches host wiring mistakes early
- multi-host trees can keep separate routing authorities in the same hierarchy

### Sibling hosts and duplicate registration

Each `NavigationHost` / `ModalHost` / `FlowHost` owns its own
`*EnvironmentStorage` instance through `@State`, so SwiftUI scopes the
handler table to the host's view subtree. Re-registering the
same routing authority is allowed across SwiftUI updates, even when
the forwarding closure is freshly allocated. A sibling host with a
different authority that registers against the same `Route` type in
the same environment scope is treated as a wiring bug: in Debug
builds the storage setter traps with `assertionFailure`, and in
Release it logs an error through the `duplicate-dispatcher`
`os_log` category before letting the overwrite proceed (preserving
prior behaviour for production cold-starts).

If two surfaces legitimately need different routing authorities,
either give them distinct `Route` types or scope them with separate
environment subtrees so each host gets its own storage.

Low-level tests or custom integrations that write directly into an
environment storage should either assign a handler once per storage
instance, or call the explicit owner registration helper with a stable
store / coordinator identity. The host modifiers do this for normal
`NavigationHost`, `ModalHost`, and `FlowHost` usage.

## Flow and tab coordinators

`StepCoordinator` and `TabCoordinator` complement `NavigationStore`; they do not replace it.

Recommended mental model:

- `NavigationStore` owns route-stack authority
- `TabCoordinator` owns shell tab state
- `StepCoordinator` owns local step state inside a destination

Use composition rather than trying to collapse all three responsibilities into one type.
