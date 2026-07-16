# Migrating from InnoRouter 4.x to 5.0

@Metadata {
  @PageKind(article)
}

Move a 4.x application to the macro-first 5.0 surface in deliberate stages.
InnoRouter 5 removes compatibility shims and implementation-facing public API,
but keeps state-driven navigation, modal, flow, and deep-link behavior as the
advanced foundation beneath the generated hosts.

## Before changing source

Confirm the application can use the 5.0 toolchain and deployment floors:

- Swift 6.3 or newer
- iOS and iPadOS 18 or newer
- macOS 15 or newer
- tvOS 18 or newer
- watchOS 11 or newer
- visionOS 2 or newer

Update the package requirement first, then resolve and build before editing
call sites. This separates toolchain or dependency-resolution failures from
source migration errors.

```swift skip package-manifest-fragment
.package(
    url: "https://github.com/InnoSquadCorp/InnoRouter.git",
    from: "5.0.0"
)
```

## Choose the dependency surface

Most application targets should depend on the `InnoRouter` product and use one
import. It now includes the macro declarations and the runtime needed by their
generated conformances.

```swift skip import-fragment
import SwiftUI
import InnoRouter
```

Use granular products only for targets that intentionally avoid the macro
plugin. Add `InnoRouterEffects` for reducer or app-boundary execution, and add
`InnoRouterSpatial` separately for visionOS scenes. The default umbrella does
not re-export either opt-in product.

| 4.x dependency or import | 5.0 replacement |
|---|---|
| `InnoRouter` plus a separate macro product | `InnoRouter` |
| `InnoRouterNavigationEffects` | `InnoRouterEffects` |
| `InnoRouterDeepLinkEffects` | `InnoRouterEffects` |
| Spatial symbols from Core or SwiftUI | `InnoRouterSpatial` |

## Adopt the macro-first host boundary

For a self-contained feature, declare destinations on one `@Router` enum,
install the narrowest generated host, and route from descendants through
`@EnvironmentRouter`.

```swift skip migration-example
@Router
enum AppRoute {
    case detail(id: String)
    case settings

    var destination: some View {
        switch self {
        case .detail(let id):
            DetailView(id: id)
        case .settings:
            SettingsView()
        }
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) {
            HomeView()
        }
    }
}

struct HomeView: View {
    @EnvironmentRouter(AppRoute.self) private var router

    var body: some View {
        Button("Settings") {
            router.go(.settings)
        }
    }
}
```

Select the host by authority:

| Feature boundary | 5.0 macro-first host |
|---|---|
| Stack plus sheet or cover | `RouterHost` |
| Modal only | `RouterModalHost` |
| Split detail stack plus modal | `RouterSplitHost` |
| Native tabs | `RouterTabHost` |
| visionOS window, volume, or immersive space | `@SceneRouter` with `InnoRouterSpatial` |

Keep an externally owned `NavigationStore`, `ModalStore`, or `FlowStore` when
restoration, middleware mutation, pending deep-link replay, direct observation,
or application-wide policy needs authority outside the host.

## Replace environment wrappers

The route-typed environment wrappers are unified:

| 4.x | 5.0 |
|---|---|
| `@EnvironmentNavigationIntent` | `@EnvironmentRouter` |
| `@EnvironmentModalIntent` | `@EnvironmentRouter` |
| `@EnvironmentFlowIntent` | `@EnvironmentRouter` |
| `navigation.send(.go(route))` | `router.go(route)` |
| `modal.send(.present(route, style: .sheet))` | `router.sheet(route)` |
| `flow.send(.reset(...))` | `router.send(flow: .reset(...))` |

One route type now resolves one complete nearest authority. Use
`RouterHost` or `FlowHost` when stack and modal actions share a route type. Use
different route enums when those surfaces have independent owners.

## Consolidate observation

Store-specific callbacks and telemetry sink protocols are replaced by one
typed callback and one asynchronous stream per authority.

```swift skip migration-example
let configuration = NavigationStoreConfiguration<AppRoute>(
    onEvent: { event in
        switch event {
        case .changed(_, let newState):
            analytics.record(newState.path)
        case .batchExecuted(let result):
            analytics.record(result)
        default:
            break
        }
    }
)
```

Replace `onChange`, batch, transaction, middleware, path-mismatch, modal, and
flow callbacks with the corresponding `NavigationEvent`, `ModalEvent`, or
`FlowEvent` case. Replace `StoreObserver` and `observe(_:)` with the store's
`events` `AsyncStream`. Capture the stream before starting its lifecycle-owned
task so an immediate first event cannot race subscriber registration.

## Update effects and deep links

`NavigationEffectHandler` now returns results for every operation. Replace the
result-discarding convenience methods with commands and handle failure or
cancellation explicitly.

```swift skip migration-example
let result = handler.execute(.push(.detail(id: "42")))
guard result.isSuccess else {
    // Report or recover at the application boundary.
    return
}
```

Deep-link coordination moves to `InnoRouterEffects`:

| 4.x | 5.0 |
|---|---|
| `DeepLinkCoordinating` | Own `DeepLinkEffectHandler` |
| `handleDeepLink(_:)` | `handle(_:)` |
| `resumePendingDeepLinkIfPossible()` | `resumePendingDeepLink()` |
| `DeepLinkCoordinationOutcome` | `DeepLinkEffectHandler.Result` |
| `FlowDeepLinkMatcher<Route>` | `DeepLinkMatcher<FlowPlan<Route>>` |
| `DeepLinkPipeline(resolve:)` | `DeepLinkPipeline(matcher:)` |

Handle the new `executionFailed(plan:batch:)` outcome in exhaustive switches.
It distinguishes runtime command or middleware failure from preflight
`applicationRejected` outcomes. Flow rejections now carry an exact
`FlowRejectionReason`.

## Update advanced navigation code

| Removed or changed 4.x API | 5.0 migration |
|---|---|
| Custom `NavigationPathReconciling` | `NavigationPathMismatchPolicy.custom` |
| `NavigationStoreConfiguration.engine` | Remove the argument; stores own the stateless engine |
| `validate(on:using:)` / `canExecute(on:using:)` | `validate(on:)` / `canExecute(on:)` |
| Public middleware handle initializers | Retain the handle returned by registration |
| `AnyNavigator` / `AnyBatchNavigator` | Pass a concrete store or use generic `Navigator` constraints |
| `FlowNavigating` / `FlowStateReading` | Own and read `FlowStore` directly |
| `FlowCoordinator` / `FlowCoordinatorView` | `StepCoordinator` / `StepCoordinatorView` |
| `Coordinator.push(child:)` | `await child.waitForResult()` |
| `LifecycleAware` / task tracker helpers | App-owned lifetime and `parentDidCancel()` |

Review two deliberate behavior changes: an empty transaction no longer
commits, and a failed `.whenCancelled` fallback rolls back to the original
snapshot instead of retaining partial fallback state.

## Update tabs, Spatial, and tests

Manual `RouterTab` conformances now return `LocalizedStringResource` from
`title`. A literal passed to `@TabItem` already generates the correct value.

For visionOS, add `InnoRouterSpatial`, import it at scene call sites, declare
scenes with `@SceneRouter`, and interact through `SceneStore`, its `events`,
and the public scene host or anchor modifiers. Do not construct
`SceneDeclaration`, inspect `SceneRegistry` storage, or drive host completion
methods directly.

In `InnoRouterTesting`, replace the legacy test-event aliases with
`NavigationEvent`, `ModalEvent`, and `FlowEvent`. Use `finish()` as the terminal
assertion and reserve `assertNoPendingEvents()` for checkpoints between test
phases.

## Final migration checklist

- The app and every package target resolve with Swift 6.3.
- Standard targets depend only on `InnoRouter`; opt-in targets explicitly add
  Effects or Spatial.
- Local route surfaces use `@Router`, a generated host, and
  `@EnvironmentRouter` unless an advanced ownership requirement is documented.
- Observation uses `onEvent` or `events`, with no removed telemetry sinks or
  observer adapters.
- Effect and deep-link result switches handle failure and rejection payloads.
- visionOS targets import `InnoRouterSpatial` directly.
- Tests call `finish()` and use canonical production event types.
- Every supported Apple platform builds, and incoming URLs, restoration,
  middleware cancellation, modal dismissal, and pending replay are exercised.

For the exhaustive removed-symbol and behavior list, read the `5.0.0` section
of the repository's `CHANGELOG.md` alongside this task-oriented guide.
