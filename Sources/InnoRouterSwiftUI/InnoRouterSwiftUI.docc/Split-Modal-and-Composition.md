# Split, modal, and composition patterns

@Metadata {
  @PageKind(article)
}

Choose one macro-first host for the local surface. `RouterHost` and
`RouterSplitHost` unify stack and modal actions, `RouterModalHost` narrows a
feature to modal actions, and `RouterTabHost` owns native tab state.
Externally owned stores and coordinator hosts remain advanced authorities.

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

Use `RouterModalHost` when a feature needs only sheet and cover presentation:

```swift skip doc-fragment
RouterModalHost(AppRoute.self) {
    ModalLauncher()
}
```

Descendants use the same typed environment router as every other macro-first
surface:

```swift skip doc-fragment
@EnvironmentRouter(AppRoute.self) private var router

Button("Edit") {
    router.sheet(.editor)
}

Button("Preview") {
    router.cover(.preview)
}
```

`RouterModalHost` owns its `ModalStore` locally and publishes only modal
capability. An accidental `go` call therefore reports a missing navigation
capability instead of silently inventing a stack.

Use `ModalStore` with `ModalHost` when restoration, middleware management, or
direct observation requires the application to own the modal authority.

On iOS and tvOS, `ModalHost` uses native `sheet` and `fullScreenCover` presentation.
On other supported platforms, `fullScreenCover` requests degrade to `sheet`.

The advanced modal authority intentionally stays separate from a stack-only
authority:

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

Every convenience mutator reports its effective outcome as a
`@discardableResult`: `present` returns `ModalPresentResult`, while
`replaceCurrent`, `dismissCurrent`, and `dismissAll` return the same
`ModalExecutionResult` that `execute(_:)` produces. Callers can branch on a
middleware cancellation or an empty-state `.noop` directly at the call site
instead of subscribing to the event stream; call sites that ignore the
result compile unchanged.

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

`@DeepLink` does not choose a modal presentation style. Automatic URL handling
pushes through `RouterHost` / `RouterSplitHost` or selects through
`RouterTabHost`; an application that needs a URL to open a sheet or cover must
apply that policy at its flow boundary.

## Composition

The recommended composition rules are:

1. Choose exactly one local macro-first authority for a route type in a
   subtree: `RouterHost`, `RouterModalHost`, `RouterSplitHost`, or
   `RouterTabHost`.
2. Put shell state such as tabs or app mode outside feature-local routing.
3. Use distinct route types for nested authorities that must remain
   independent.
4. Promote to `NavigationHost`, `ModalHost`, `FlowHost`, or a coordinator host
   only when the application owns that state.
5. Keep feature-local routing inside the destination that owns it.

Do not wrap `RouterHost` in `RouterModalHost` for the same route type:
`RouterHost` already owns both capabilities, and a nested same-route host
replaces the outer authority for its subtree. These rules keep each authority
narrow without creating one application-wide store.
