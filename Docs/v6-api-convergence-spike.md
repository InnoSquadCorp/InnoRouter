# InnoRouter 6.0 API Convergence

- Status: Draft
- Implementation state: spike accepted in the local release candidate
- As of: 2026-09-03

## Selected vocabulary

6.0 has two route-generic request values:

- `RouterAction<Route>` describes an incremental request.
- `RouterPlan<Route>` describes one exact, structurally valid target state.

`RouterTransition`, `RouterOutcome`, and `RouterEvent` describe execution; they
are not additional request languages.

## Canonical shape

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case home
    case detail(id: String)
    case editor

    var destination: some View { EmptyView() }
}

@MainActor
func openDetail(in store: RouterStore<AppRoute>) async {
    let outcome = await store.perform(.push(.detail(id: "42")))
    _ = outcome
}
```

The complete state recursively represents stack and container nodes, tab or
split selection, normalized badges, one presentation per stack, regular
windows, and one immersive space. A `RouterPlan` wraps that exact state, so a
deep link, transaction, and restore all target the same model.

## Migration matrix

| 5.x surface | 6.0 replacement |
| --- | --- |
| `NavigationStore`, `ModalStore`, `FlowStore` | `RouterStore` |
| `NavigationIntent`, `ModalIntent`, `FlowIntent` | `RouterAction` |
| `NavigationPlan`, `FlowPlan` | `RouterPlan` |
| `AppShellStore`, `AdaptiveSplitStore` | `RouterState.container` plus `RouterTabHost` or `RouterSplitHost` |
| `StatePersistence`, `StateRestorationAdapter` | `RouterSnapshotCodec`, `RouterStore.restore`, and opt-in `RouterRestorationDriver` |
| `DeepLinkPipeline`, `FlowDeepLinkPipeline` | `RouterLinkPipeline` |
| `AsyncNavigationMiddlewareExecutor` | `RouterPolicy` in `RouterStoreConfiguration` |
| `ChildCoordinator.waitForResult()` and callbacks | `RouterStore.present(_:expecting:)` and `finishPresentation(returning:)` |
| per-store test harnesses | `RouterTestStore` |
| per-domain inspector attachments | canonical `RouterStore` attachment |
| granular runtime/effect/scene products | `InnoRouter` |

## Outcome contract

Every request owns one `RouterTransitionID`. The same identifier is present in
the returned outcome and every emitted lifecycle event. Terminal outcomes are:

- `applied`: one state assignment and one revision increment;
- `unchanged`: a valid no-op with no revision increment;
- `rejected`: mutation, policy, busy, stale, cancellation, or missing-authority
  reason with the previous committed state.

## Why old layers are not public adapters

Leaving old stores public would preserve the main 5.x product-design problem:
developers could still create competing authorities and choose between several
meanings of “plan.” Keeping them in Git history preserves migration evidence
while ensuring retired source cannot re-enter the active build graph by
accidental target discovery or repository-wide tooling.

## Resolved pre-release decisions

- `RouterSceneDriver` ships in the first 6.0 candidate and reconciles window and
  immersive state through native SwiftUI scene actions.
- Macro-generated `@Scene` metadata and the App Intent/Handoff URL bridges ship
  in the first 6.0 candidate as part of the planned 6.1 capability set.
- The pre-release 6.2 capability set adds macro-first state reads, pending-plan
  continuation, app-selected automatic restoration, and imported developer
  sessions without introducing another router authority.
- The best-effort 6.3 capability set adds payload-safe observability and typed
  shortcut route catalogs; concrete localized App Intents remain app-owned.

Manual `RouterTab` conformances already require an explicit durable scope
identifier. Macro-generated tabs persist exact case-name IDs automatically;
this is part of the selected 6.0 contract, not an open question.
