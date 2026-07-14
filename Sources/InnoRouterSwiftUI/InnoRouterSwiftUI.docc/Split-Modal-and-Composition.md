# Split, modal, and composition patterns

@Metadata {
  @PageKind(article)
}

Stack navigation, split detail navigation, and modal presentation are intentionally separate authorities.

## Split navigation

Use `NavigationSplitHost` or `CoordinatorSplitHost` when the app has a sidebar/detail layout.

Important scope boundary:

- InnoRouter owns only the detail stack
- sidebar selection remains app-owned
- column visibility remains app-owned
- compact adaptation remains app-owned

This keeps shell state out of the stack authority.

> Platform: `NavigationSplitHost` and `CoordinatorSplitHost` are **unavailable on watchOS**
> because SwiftUI's `NavigationSplitView` is unavailable there. watchOS apps should fall back
> to `NavigationHost` / `CoordinatorHost` in the `#else` branch of a
> `#if !os(watchOS)` check.

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
3. `NavigationHost` or `CoordinatorHost` for stack routing
4. feature-local flow state inside a destination

This keeps each authority narrow and avoids one giant store owning every kind of navigation.
