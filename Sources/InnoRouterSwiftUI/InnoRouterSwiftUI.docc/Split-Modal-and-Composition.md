# Split, modal, and composition patterns

@Metadata {
  @PageKind(article)
}

Macro-first hosts can unify a detail stack and modal presentation under one
`FlowStore`. Externally owned stack, modal, and coordinator hosts remain
separate advanced authorities.

## Split navigation

Use `RouterSplitHost` for a macro-first sidebar/detail layout. It owns the
detail stack and modal authority locally, builds destinations from the
`@Router` enum, and exposes both through `@EnvironmentRouter`:

```swift skip doc-fragment
RouterSplitHost(AppRoute.self) {
    SidebarView()
} root: {
    ContentUnavailableView("Select an item", systemImage: "sidebar.left")
}
```

All stack and modal actions pass through the same `FlowStore`, so a push is
still rejected while a modal route is the flow tail. Use
`NavigationSplitHost` or `CoordinatorSplitHost` when the application must own
an advanced stack-only authority directly.

Important scope boundary:

- `RouterSplitHost` owns the detail stack and modal authority
- advanced split hosts own only the detail stack
- sidebar selection remains app-owned
- column visibility remains system-managed
- compact adaptation remains system-managed

This keeps shell state out of the stack authority.

> Platform: `NavigationSplitHost` and `CoordinatorSplitHost` are **unavailable on watchOS**
> because SwiftUI's `NavigationSplitView` is unavailable there. watchOS apps should fall back
> to `NavigationHost` / `CoordinatorHost` in the `#else` branch of a
> `#if !os(watchOS)` check.
>
> `RouterSplitHost` remains visible to watchOS callers as an explicitly
> unavailable declaration, whose compiler diagnostic directs macro-first code
> to `RouterHost`.

## Modal navigation

Use `ModalStore` with `ModalHost` when `sheet` or `fullScreenCover` should be routed with the same discipline as stack navigation.

On iOS and tvOS, `ModalHost` uses native `sheet` and `fullScreenCover` presentation.
On other supported platforms, `fullScreenCover` requests degrade to `sheet`.

Modal routing intentionally stays separate from stack routing:

- modal intent uses `ModalIntent`
- stack intent uses `NavigationIntent`
- modal queue state lives in `ModalStore`
- stack state lives in `NavigationStore`

Modal queue rules are intentionally small:

- `present` shows immediately when no modal is active.
- `present` appends to `queuedPresentations` when another modal is
  active.
- `dismissCurrent` dismisses the active modal and promotes the first
  queued presentation, if one exists.
- `dismissAll` clears both the active modal and the queue.
- `replaceCurrent` swaps only the active presentation and leaves the
  queue untouched; observers receive `.replaced` before the command
  interception event.

`dismissCurrent` and `dismissAll` attempts enter modal middleware even when
there is no active presentation or queue. The resulting command can remain a
no-op, be cancelled, or be rewritten by middleware; this matches direct
`ModalStore` execution instead of hiding empty-state attempts in `FlowStore`.

When middleware cancels a FlowStore modal preview, the captured participants
still receive `didExecute`, observers receive `.commandIntercepted`, and
`ModalQueueCancellationPolicy` is applied to the preview state. If that policy
changes the live queue, `.queueChanged` is delivered before the interception
and flow-level rejection. During an atomic reset, a cancellation previewed from
an intermediate shadow is finalized with the actual live state that survived
rollback. Successful navigation and modal previews that preceded that
cancellation stay off the public `didExecute` path and run their package-owned
discard cleanup instead.

`alert` and `confirmationDialog` stay outside this framework surface and should remain feature-owned state.

`ModalStoreConfiguration` uses one `onEvent` callback for the complete
modal observation surface:

```swift skip doc-fragment
let configuration = ModalStoreConfiguration<AppRoute>(
    onEvent: { event in
        switch event {
        case .presented(let presentation):
            analytics.recordPresented(presentation)
        case .dismissed(let presentation, let reason):
            analytics.recordDismissed(presentation, reason: reason)
        case .replaced(let old, let new):
            analytics.recordReplacement(from: old, to: new)
        case .queueChanged(let old, let new):
            diagnostics.recordQueueChange(from: old, to: new)
        case .commandIntercepted(let command, let result):
            diagnostics.record(command, result: result)
        case .middlewareMutation(let mutation):
            diagnostics.record(mutation)
        }
    }
)
```

When migrating to 5.0, merge the former modal lifecycle closures into
this switch. `ModalStore.events` emits the same cases asynchronously.

## Composition

The recommended composition order is:

1. shell state such as tabs or app mode
2. `ModalHost` if modal routing should be shared
3. `RouterHost` for a local stack, or `NavigationHost` /
   `CoordinatorHost` when the application owns the routing authority
4. feature-local flow state inside a destination

This keeps each authority narrow and avoids one giant store owning every kind of navigation.
