# Intent vs Command vs Plan — Selection Guide

InnoRouter exposes four different request types. Picking the wrong
one is the most common source of "why is my flow rejected?" friction
in code reviews, so this guide names each one and points at the use
case it was designed for.

## At a glance

| Surface | Type | Use when |
|---|---|---|
| Stack view facade (default) | `RouterActions<R>` | A view reads `@EnvironmentRouter` and calls `go`, `back`, or another named action without knowing about the store. |
| Explicit intent | `NavigationIntent<R>` / `ModalIntent<M>` / `FlowIntent<R>` | A transition needs a lower-level intent value. Use `router.send(_:)` for navigation or modal intents and `router.send(flow:)` for flow-only intents. |
| Imperative low-level | `NavigationCommand<R>` / `ModalCommand<M>` | You hold a store reference and want explicit control over a single push, pop, present, or replace. Middleware sees this. |
| Composite multi-step | `FlowPlan<R>` | A deep link, restoration snapshot, or pre-built scenario commits a whole push prefix + modal tail in one shot. |

## NavigationCommand vs NavigationIntent

`NavigationCommand<R>` is the lowest-level instruction the engine
understands: `.push(R)`, `.pop`, `.popTo(R)`, `.replace([R])`, etc. It
goes through `NavigationStore.execute(_:)` and `executeBatch(_:)` and
fires every middleware in the registry.

`RouterActions<R>` is the default stack-view facade. Read it with
`@EnvironmentRouter(Route.self)` and call `go`, `back`, `back(to:)`, or
`backToRoot` for ordinary transitions.

`NavigationIntent<R>` is the complete intent vocabulary: `.go(R)`,
`.back`, `.backTo(R)`, `.backOrPush(R)`, `.pushUniqueRoot(R)`,
`.replaceStack([R])`. A child view that needs a case without a named facade
method sends it with `router.send(_:)`. An application boundary that
deliberately owns a `NavigationStore` can use `store.send(_:)`. The store maps
each intent to one or more commands and runs them through the same pipeline.

Use **commands** in app-boundary code (effect handlers, deep-link
coordinators, test scaffolding) where you want exact control. Use
the **router facade** in ordinary stack views, and explicit **intents** only
when the facade does not express the transition or the modal/flow surface owns
the semantics.

## ModalCommand vs ModalIntent

`ModalCommand<M>` is `.present(ModalPresentation<M>)`,
`.replaceCurrent(ModalPresentation<M>)`, `.dismissCurrent(reason:)`,
`.dismissAll`. `ModalIntent<M>` is the view-layer wrapper:
`.present(M, style:)`, `.dismiss`, `.dismissAll`.

The same imperative-vs-view-layer split applies. Ordinary views call
`router.sheet`, `router.cover`, `router.dismiss`, or `router.dismissAll`.
Use `router.send(ModalIntent.present(...))` when the presentation style is
chosen dynamically or an explicit intent value must cross an app boundary.
Inside a `FlowHost`, these actions still enter through `FlowStore` and preserve
its modal-tail invariant.

## NavigationIntent vs FlowIntent

`FlowIntent<R>` names operations against the unified push-plus-modal timeline
owned by `FlowStore<R>`. Common push, pop, presentation, and dismissal actions
remain available through the same `@EnvironmentRouter` facade. Reach for an
explicit `FlowIntent` when the operation itself is flow-specific, especially:

- `.reset([RouteStep<R>])` — replace the complete push prefix and modal tail
- `.backOrPushDismissingModal(R)` — pop modal tail, then either pop
  back to an existing push or push fresh
- `.pushUniqueRootDismissingModal(R)` — same, but only push if the
  root doesn't already contain that route

Views send these with `router.send(flow:)`; application boundaries that own the
store call `flowStore.send(_:)`. `FlowHost` projects named navigation and modal
actions into the equivalent `FlowIntent`, so choosing the simpler facade never
bypasses the flow authority.

## When to use FlowPlan

`FlowPlan<R>` is the composite type for "land the user in *exactly*
this state." It carries an ordered list of `RouteStep<R>` values
(push / sheet / cover) and is the unit that `FlowDeepLinkPipeline`
returns. Use a `FlowPlan` when:

- A deep link rehydrates a multi-step screen flow including a modal
  tail.
- Restoration replays a saved snapshot at app launch.
- A test sets up a known starting point in one shot.

`FlowStore.apply(_:)` runs every step through the same middleware
chain that intents and commands use, so middleware decisions still
apply.

## Quick decision flowchart

```text
Are you in an ordinary SwiftUI view?
├── Yes → use @EnvironmentRouter named actions
│        └── Need an exact intent value?
│            ├── Navigation / modal → router.send(_:)
│            └── Flow-only         → router.send(flow:)
└── No  → are you composing a multi-step landing surface?
         ├── Yes → use FlowPlan
         └── No  → use send / execute at the owning store or effect boundary
```

## Pitfalls

1. **Don't reach into `flowStore.navigationStore.execute(...)`.**
   Direct inner-store mutation bypasses FlowStore-level invariants
   such as the modal-tail block on `push` while a sheet is up. Use
   the FlowStore surface (`apply` / `send` with a `FlowIntent`) in
   flow scenarios. The inner stores are implementation details reserved for
   rendering surfaces and focused package-internal invariant tests.
2. **Don't pick `NavigationCommand.replace([])` to "reset".** An
   empty replace clears the stack but is a single command; a clear
   reset of an in-flight flow is `flowStore.send(.reset([]))`.
3. **Don't synthesise composite plans from `FlowIntent` chains.**
   A sequence of `.push` + `.presentSheet` runs middleware twice and
   surfaces two `.pathChanged` events; `FlowPlan` runs the same
   surface as one transactional commit with one event.
