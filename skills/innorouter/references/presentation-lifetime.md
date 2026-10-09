# Typed presentation and lifetime

`@PresentationResult(Bool.self) case confirmation` generates
`AppRoute.Presentation.confirmation`, a typed `RouterPresentationRequest`. Await
`router.present(request)` and complete from the presented destination with
`try await router.finishPresentation(request, returning: value)`. Handle errors
according to the UI; do not erase route/result mismatch or policy rejection.

For an alert or dialog use `RouterTransientPresentationRequest<Value>.alert` or
`.confirmationDialog` with stable button IDs, labels, roles and declared values.
`Value: Sendable` is not serialized or invoked by the router. One scope has one
exclusive `presentationFamily` (navigation, alert, or confirmation dialog).
`presentation` is only the navigation compatibility view.

```swift
let request = RouterTransientPresentationRequest<Bool>.confirmationDialog(
    title: "Remove item?",
    actions: [
        .init(id: "remove", label: "Remove", role: .destructive, value: true),
        .init(id: "keep", label: "Keep", role: .cancel, value: false),
    ]
)
let outcome = await store.present(request)
```

A selected cancel-role button returns its declared `.value(false)`, not
`.cancelled`. Dismissal without selection returns `.dismissed`; caller cancellation
or removed/replaced ownership returns `.cancelled`. Handle `.rejected` separately.
A rejected/deferred removal leaves state and waiters until an accepted transition.

For a custom renderer, capture `presentationHandle()` for that presentation and
send `selectPresentationAction(_:using:)` or `dismissPresentation(using:)` with it.
Do not reacquire a current handle inside an old callback: that would substitute new
authority for an expired one. Same presentation UUID after replacement is not the
same execution lifetime. Direct dismissal differs from parent removal cancelling
descendant waiters. Application authorization generations must be explicitly supplied
when account/session changes need to invalidate queued work.

In async tests subscribe to `store.events` before starting a presentation task,
await its committed event, then capture the handle and complete/cancel it. Await
the task's outcome and clean up on failure. Use bounded test time limits rather
than sleeps or arbitrary `Task.yield()` counts. [Consumer tests](../assets/consumer/Tests/RouterSkillExampleTests/ConsumerTests.swift)
cover declared cancel value, caller cancellation and encode-only omission.

Release contracts: [7.0 migration](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md),
[presentation handles](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/Sources/InnoRouterSwiftUI/RouterPresentationHandle.swift).
