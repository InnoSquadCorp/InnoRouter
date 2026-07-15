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

`EnvironmentRouter` is the primary route-action API for views. It exposes
discoverable `RouterActions` methods such as `go`, `sheet`, and, for a
`RouterTab`, `select` without revealing host-owned state. Advanced
`NavigationIntent` values remain available through the explicit `send(_:)`
escape hatch:

```swift skip doc-fragment
struct ProductRow: View {
    @EnvironmentRouter(AppRoute.self) private var router

    let productID: String

    var body: some View {
        Button("Open") {
            router.go(.product(id: productID))
        }

        Button("Replace stack") {
            router.send(.replaceStack([.catalog, .product(id: productID)]))
        }
    }
}
```

`EnvironmentNavigationIntent` remains the lower-level stack surface for code
that needs to construct `NavigationIntent` directly. `EnvironmentModalIntent`
and `EnvironmentFlowIntent` provide the corresponding modal and unified-flow
dispatchers.

This keeps view code declarative:

- child views do not need a direct store reference
- macro diagnostics catch invalid `@Router` declarations at compile time
- fail-fast environment behavior catches host wiring mistakes at runtime
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

`RouterTabHost` is the macro-first tab surface. It owns selection and badge
state locally, renders every generated `RouterTab` case through native
`TabView`, and exposes `select`, `setBadge`, `clearBadge`, and
`clearAllBadges` through `EnvironmentRouter`:

```swift skip doc-fragment
struct InboxButton: View {
    @EnvironmentRouter(AppTab.self) private var router

    var body: some View {
        Button("Inbox") {
            router.select(.inbox)
            router.setBadge(3, for: .inbox)
        }
    }
}
```

`StepCoordinator` and `TabCoordinator` remain advanced composition tools and
complement `NavigationStore`; they do not replace it.

Recommended mental model:

- `NavigationStore` owns route-stack authority
- `RouterTabHost` owns local macro-first shell tab state
- `TabCoordinator` owns externally managed or custom-shell tab state
- `StepCoordinator` owns local step state inside a destination

Use composition rather than trying to collapse all three responsibilities into one type.
