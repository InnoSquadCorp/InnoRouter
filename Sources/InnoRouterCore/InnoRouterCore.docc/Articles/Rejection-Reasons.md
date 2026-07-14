# Rejection Reasons catalog

@Metadata {
  @PageKind(article)
}

One-stop reference for every rejection / cancellation / failure
taxonomy in the InnoRouter stack — when each case fires, where it
originates, and how to handle it.

## Overview

InnoRouter deliberately surfaces failure modes as typed values rather
than opaque codes. Each authority owns its own rejection taxonomy, and
all of them reach consumers through either a `Configuration` callback,
the unified `events: AsyncStream`, or a store method's return value.
In 5.0 that synchronous configuration surface is one typed `onEvent`
callback per store rather than one callback per event case.

The table below groups every rejection type by authority. Follow the
link under "Symbol" for the full symbol reference with cases and
associated values.

## Navigation

| Source | Symbol | Emits through |
|---|---|---|
| `NavigationEngine.apply(_:to:)` on invalid commands | `NavigationResult` non-`.success` cases | `NavigationStore.execute(_:)` return + `NavigationEvent.changed` |
| Middleware `willExecute` returning `.cancel(_)` | `NavigationCancellationReason` | `NavigationResult.cancelled(_)` |

### `NavigationResult` failure cases

| Case | When it fires | Typical handling |
|---|---|---|
| `.cancelled(reason)` | Middleware cancelled the command | Inspect `reason` (`.middleware`, `.conditionFailed`, `.custom(_)`) |
| `.emptyStack` | `.pop` / `.popCount` / `.popToRoot` on an already-empty stack | Treat as no-op, or gate the intent upstream |
| `.invalidPopCount(Int)` | Negative or zero pop count | App-level validation bug; audit the call site |
| `.insufficientStackDepth(requested:available:)` | Asked to pop more frames than exist | Clamp the pop count or treat as `popToRoot` |
| `.routeNotFound(R)` | `.popTo(route:)` cannot find the target | Surface "history was cleared" UI; upstream intent likely assumed stale state |
| `.multiple([NavigationResult])` | Aggregated result from `.sequence([_])` | Iterate the children; outer success requires every child success |

### `NavigationCancellationReason`

| Case | When it fires |
|---|---|
| `.middleware(debugName:command:)` | A registered middleware cancelled the command; `debugName` identifies which one |
| `.conditionFailed` | A `NavigationInterception.cancel(.conditionFailed)` was returned |
| `.custom(String)` | A middleware surfaced a custom reason string |

## Modal

| Source | Symbol | Emits through |
|---|---|---|
| Middleware `willExecute` returning `.cancel(_)` | `ModalCancellationReason` | `ModalEvent.commandIntercepted(command:result:)` with `.cancelled(_)` |

### `ModalCancellationReason`

Identical shape to `NavigationCancellationReason` but parameterised on
`ModalCommand<M>`:

| Case | When it fires |
|---|---|
| `.middleware(debugName:command:)` | A modal middleware cancelled the `.present` / `.dismissCurrent` / `.dismissAll` |
| `.conditionFailed` | Interception returned `.cancel(.conditionFailed)` |
| `.custom(String)` | Middleware surfaced a custom string |

## Flow

| Source | Symbol | Emits through |
|---|---|---|
| `FlowStore.send(_ intent:)` refusal | `FlowRejectionReason` | `FlowStoreConfiguration.onEvent` / `FlowStore.events` as `FlowEvent.intentRejected` |
| `FlowStore.apply(_ plan:)` rejection | `FlowPlanApplyResult.rejected(currentPath:reason:)` | Synchronous return value with the exact `FlowRejectionReason` |

### `FlowRejectionReason`

| Case | When it fires | Typical handling |
|---|---|---|
| `.pushBlockedByModalTail` | `.push(_)` requested while the flow tail is a `.sheet` / `.cover` step | Dismiss first, or use `.reset(_:)` |
| `.invalidResetPath` | A `.reset([_])` path violates FlowStore invariants (e.g. multiple modal steps, or a modal not at the tail) | Fix the path before sending |
| `.middlewareRejected(debugName:)` | A navigation or modal middleware inside the flow cancelled the underlying command; `FlowStore.path` was rolled back | Observe which middleware; surface telemetry |
| `.reentrantApply` | `FlowStore.apply(_:)` was called synchronously while the store was already delivering a mutation event | Schedule `send(.reset(_))` from the callback so the mutation is deferred |

## Scene (visionOS)

| Source | Symbol | Emits through |
|---|---|---|
| `SceneStore` intent validation | `SceneRejectionReason` | `SceneEvent.rejected(_:reason:)` + `SceneEvent.hostRegistrationRejected(reason:)` |

### `SceneRejectionReason`

| Case | When it fires | Typical handling |
|---|---|---|
| `.environmentReturnedFailure` | `OpenImmersiveSpaceAction.Result` was `.userCancelled` or `.error` | User intent; surface a retry affordance if appropriate |
| `.nothingActive` | `dismissImmersive()` called with no active immersive space | Gate upstream; or ignore as idempotent |
| `.activeSceneMismatch` | Dismiss target does not match the active scene | Inventory is out of sync; inspect `store.currentScene` |
| `.sceneNotDeclared` | Requested route missing from the shared `SceneRegistry` | Add the declaration, or fix the route |
| `.sceneDeclarationMismatch` | Presentation kind / size / style does not match the registry entry | Use the registry's declaration unchanged |
| `.supersededByNewerIntent` | A newer intent replaced the pending one before the host committed it | Expected during rapid intent bursts; no action |
| `.fallbackCannotDispatch` | A fallback `SceneAnchor` cannot serve a cross-scene open (the primary `SceneHost` scene is not live) | Re-attach a `SceneHost`, or surface UI asking the user to focus the target scene |
| `.duplicateHostRegistration` | A second `SceneHost` tried to register with the same store | Enforce one host per store; usually a SwiftUI scene-rehydration artefact |
| `.hostTornDownDuringDispatch` | The dispatcher's `Task` was cancelled while a claimed intent was mid-flight | Re-issue the intent once a host is live again |

## Deep links

| Source | Symbol | Emits through |
|---|---|---|
| `DeepLinkPipeline.handle(_:)` URL policy | `DeepLinkRejectionReason` (wrapped in `DeepLinkDecision.rejected`) | `DeepLinkCoordinationOutcome.rejected` via `DeepLinkEffectHandler` |

### `DeepLinkRejectionReason`

| Case | When it fires | Typical handling |
|---|---|---|
| `.schemeNotAllowed(actualScheme:)` | URL scheme not in `allowedSchemes` | Log, drop the URL silently, or surface a diagnostic |
| `.hostNotAllowed(actualHost:)` | URL host not in `allowedHosts` | Same |

### `DeepLinkCoordinationOutcome`

The typed outcome from `DeepLinkEffectHandler` / `FlowDeepLinkEffectHandler`:

| Case | Meaning |
|---|---|
| `.executed(plan:batch:)` | Every command in the plan succeeded; per-command results remain available in `batch` |
| `.executionFailed(plan:batch:)` | Batch execution was attempted, but at least one command failed or was cancelled; inspect `batch.stateAfter` for partial changes |
| `.applicationRejected(plan:failure:)` | The push-only handler's preflight rejected the plan before batch execution, so navigation state is unchanged |
| `.applicationRejected(plan:path:reason:)` | The flow authority rejected an atomic plan; `path` is its snapshot at the rejection point and `reason` preserves the exact `FlowRejectionReason` |
| `.pending(_)` | Authorisation deferred; plan stored as `pendingDeepLink` for later replay |
| `.rejected(reason:)` | URL rejected by scheme/host policy — see `DeepLinkRejectionReason` above |
| `.unhandled(url:)` | URL did not resolve to any route |
| `.noPendingDeepLink` | `resumePendingDeepLink()` called with nothing stored |

## How to observe every rejection in one place

Every store exposes an `events: AsyncStream<Event>` where rejection
cases arrive alongside successful transitions. A single analytics
listener can cover the full surface:

```swift skip doc-fragment
let navigationResult = navigationStore.execute(.push(.profile))
if case .cancelled(let reason) = navigationResult {
    analytics.record("nav-cancel", reason: reason)
}
Task {
    for await event in modalStore.events {
        if case .commandIntercepted(_, .cancelled(let reason)) = event {
            analytics.record("modal-cancel", reason: reason)
        }
    }
}
Task {
    for await event in flowStore.events {
        if case .intentRejected(_, let reason) = event {
            analytics.record("flow-reject", reason: reason)
        }
    }
}
#if os(visionOS)
Task {
    for await event in sceneStore.events {
        if case .rejected(let intent, let reason) = event {
            analytics.record("scene-reject-\(intent)", reason: reason)
        } else if case .hostRegistrationRejected(let reason) = event {
            analytics.record("scene-host-reject", reason: reason)
        }
    }
}
#endif
```

Deep-link outcomes surface through `DeepLinkEffectHandler.handle(_:)`'s
return value rather than a stream, so wrap the call at the
scene-phase boundary:

```swift skip doc-fragment
let outcome = await deepLinkHandler.handle(url)
switch outcome {
case .executed, .pending, .noPendingDeepLink:
    break
case .executionFailed(_, let batch):
    analytics.record("deeplink-execution-failed", results: batch.results)
case .applicationRejected(_, let failure):
    analytics.record("deeplink-application-rejected", result: failure.result)
case .rejected(let reason):
    analytics.record("deeplink-reject", reason: reason)
case .unhandled(let url):
    analytics.record("deeplink-unhandled", url: url)
case .invalidURL(let input):
    analytics.record("deeplink-invalid-url", input: input)
case .missingDeepLinkURL:
    analytics.record("deeplink-missing-url")
}
```

## Related

- <doc:Middleware-and-Cancellation>
- <doc:Command-Batch-and-Transaction-Semantics>
