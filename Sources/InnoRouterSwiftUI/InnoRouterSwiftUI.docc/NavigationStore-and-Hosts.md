# NavigationStore and hosts

@Metadata {
  @PageKind(article)
}

`NavigationStore` is the shared stack-navigation authority for SwiftUI.

## What the store owns

`NavigationStore` owns:

- the current `RouteStack` snapshot
- command execution
- batch execution
- transactional execution
- path reconciliation from `NavigationStack(path:)`
- middleware registry orchestration
- telemetry and typed observation events

Configuration is centralized in `NavigationStoreConfiguration`.
Its synchronous observation surface is one `onEvent` callback that
switches over `NavigationEvent`; `NavigationStore.events` provides the
same cases as an `AsyncStream`.

```swift skip doc-fragment
let configuration = NavigationStoreConfiguration<AppRoute>(
    onEvent: { event in
        switch event {
        case .changed(_, let new):
            analytics.recordPath(new.path)
        case .batchExecuted(let result):
            analytics.recordBatch(result)
        case .transactionExecuted(let result):
            analytics.recordTransaction(result)
        case .middlewareMutation(let mutation):
            diagnostics.record(mutation)
        case .pathMismatch(let mismatch):
            diagnostics.record(mismatch)
        }
    }
)
```

For a 5.0 migration, move the bodies of the former per-event
configuration closures into these switch cases. No compatibility
closures remain.

## Host responsibilities

`NavigationHost` and `CoordinatorHost` connect SwiftUI navigation UI to the store or coordinator:

- render the root view
- render destinations for pushed routes
- inject environment intent closures
- bridge system path changes back into router commands

Views should not mutate a store directly. They should emit `NavigationIntent` through the environment.

`NavigationStoreConfiguration.telemetrySink` receives structured
`NavigationTelemetryEvent` values for analytics or diagnostics. When
the sink is omitted but `logger` is supplied, the store installs the
default `OSLogNavigationTelemetrySink`.

## Path reconciliation

When SwiftUI changes the path, InnoRouter translates that change back into semantic commands:

- prefix shrink -> `.popCount` or `.popToRoot`
- prefix expand -> per-step `.push` batch
- mismatch -> `NavigationPathMismatchPolicy`

This preserves command meaning instead of treating every path change as a blind replacement.

`NavigationStoreConfiguration` defaults to `.replace`, which treats the
SwiftUI binding as the source of truth for a non-prefix rewrite and emits
a `NavigationPathMismatchEvent`. For debug or pre-release builds, use
`.assertAndReplace` to make unexpected rewrites loud while still
recovering. Use `.ignore` only when the store must remain the sole
authority, and `.custom` when a host has domain-specific repair rules.
