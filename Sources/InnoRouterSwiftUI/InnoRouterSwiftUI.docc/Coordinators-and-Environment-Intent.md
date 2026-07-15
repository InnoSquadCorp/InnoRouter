# Coordinators and environment router

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

## Environment router actions

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

Use `router.send(_:)` when code needs to construct a `NavigationIntent` or
`ModalIntent` directly, and `router.send(flow:)` for an explicit `FlowIntent`.
When stack and modal authorities use different route types, declare one
`@EnvironmentRouter` property for each route type.

This keeps view code declarative:

- child views do not need a direct store reference
- macro diagnostics catch invalid `@Router` declarations at compile time
- fail-fast environment behavior catches host wiring mistakes at runtime
- multi-host trees can keep separate routing authorities in the same hierarchy

### Host scoping and authority replacement

Each `RouterHost`, `RouterModalHost`, `RouterSplitHost`, `RouterTabHost`, and
advanced store-backed host publishes one route-typed authority to its own view
subtree. SwiftUI environment value semantics keep sibling hosts independent.
When a nested host uses the same `Route` type, it replaces the complete
authority for that subtree instead of merging capabilities from two stores.

This replacement prevents an inner stack-only host from accidentally driving
an outer modal or flow authority. Different route types can coexist in one
subtree; views declare one `@EnvironmentRouter` property for each route type
they use. The registration and storage types are implementation details, so
custom view trees should compose the public hosts rather than write router
environment state directly.

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
