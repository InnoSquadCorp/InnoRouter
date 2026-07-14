# visionOS: windows, volumetric scenes, immersive spaces, and ornaments

@Metadata {
  @PageKind(article)
}

Coordinate visionOS spatial presentations through `SceneStore`,
`innoRouterSceneHost`, and `innoRouterOrnament`.

## Overview

visionOS exposes three distinct "scene" primitives that are not
modelled by `NavigationStore` / `ModalStore`:

- a regular window, declared with `WindowGroup(id:for:)`
- a volumetric window, declared with `WindowGroup(id:for:).windowStyle(.volumetric)`
- an immersive space, declared with `ImmersiveSpace(id:)`

SwiftUI's openers for these (`@Environment(\.openWindow)`,
`@Environment(\.openImmersiveSpace)`, `@Environment(\.dismissImmersiveSpace)`,
`@Environment(\.dismissWindow)`) are only reachable from a view's
`body`. InnoRouter provides a thin `SceneStore` / `innoRouterSceneHost` pair
that mirrors the `NavigationStore` / `NavigationHost` discipline:

- the store owns the desired scene state and publishes intents
- the host sits in the view tree and translates intents into the
  matching environment action
- subscribers observe outcomes through `SceneStore.events`

## Declaring scenes in your App

```swift skip doc-fragment
import SwiftUI

import InnoRouter
import InnoRouterMacros
import InnoRouterSpatial

@Routable
enum SpatialRoute {
    case main
    case theatre
}

private let spatialScenes = SceneRegistry<SpatialRoute>(
    .window(.main, id: "main"),
    .immersive(.theatre, id: "theatre", style: .mixed)
)

@main
struct MyApp: App {
    @State private var sceneStore = SceneStore<SpatialRoute>()

    var body: some Scene {
        // Host-owned scene: innoRouterSceneHost only. Do NOT also attach
        // innoRouterSceneAnchor here — the host already reconciles its own
        // scene's lifecycle, and a redundant anchor registers a
        // fallback dispatcher on the scene the host already owns.
        WindowGroup(id: "main", for: UUID.self) { $sceneID in
            ContentView()
                .innoRouterSceneHost(
                    sceneStore,
                    scenes: spatialScenes,
                    attachedTo: .main,
                    instanceID: sceneID
                )
        } defaultValue: {
            UUID()
        }

        // Non-host scene: innoRouterSceneAnchor only. Keeps the store's
        // inventory in sync with system-driven appear/disappear and
        // can temporarily serve dismissals if the host scene is gone;
        // fallback opens are still limited to this scene declaration.
        ImmersiveSpace(id: "theatre") {
            TheatreView()
                .innoRouterSceneAnchor(
                    sceneStore,
                    scenes: spatialScenes,
                    attachedTo: .theatre
                )
        }
    }
}
```

The shared `SceneRegistry` keeps route-to-id mapping and declaration
metadata in one place. It is opaque after construction: define stable scene
identifier constants and reuse them in both the registry factories and the
matching `WindowGroup` / `ImmersiveSpace` declarations.

### Which modifier goes where?

| Scene declaration | Attach `innoRouterSceneHost` | Attach `innoRouterSceneAnchor` |
|---|---|---|
| The app's primary `WindowGroup` | ✅ exactly once | ❌ redundant |
| Secondary `WindowGroup` | ❌ | ✅ |
| `ImmersiveSpace` | ❌ | ✅ |
| Any scene that isn't the host's scene | ❌ | ✅ |

A mnemonic: **"one host per store, one anchor per non-host scene"**.
`innoRouterSceneHost` is the single primary dispatcher;
`innoRouterSceneAnchor` is a
lifecycle reconciler that also serves as a restricted fallback
dispatcher for its own scene. Fallback anchors are deliberately
limited to opens for their own `SceneDeclaration` and any dismissal. For a
value-based `WindowGroup`, another window UUID under that same declaration is
allowed; a cross-scene open
arriving while the host is gone is rejected with
`SceneRejectionReason.fallbackCannotDispatch` so the queue advances
rather than silently succeeding on a scene the anchor can't reach.

Window and volumetric host or anchor scenes use the `UUID` supplied by
a value-based `WindowGroup`; immersive spaces keep the route-only
overloads.

## Opening and dismissing scenes

From anywhere that holds a reference to the store:

```swift skip doc-fragment
// In the main window:
let mainWindow = sceneStore.openWindow(.main)
sceneStore.openImmersive(.theatre, style: .mixed)

// Somewhere else later:
sceneStore.dismissWindow(mainWindow)
sceneStore.dismissImmersive()
```

`VolumetricSize` and `ImmersiveStyle` are declaration-backed metadata,
not dynamic environment parameters. If a request's kind, size, or
style does not match the registry entry, the host emits
`SceneEvent.rejected(.open(...), reason: .sceneDeclarationMismatch)`
and leaves the active scene inventory untouched.

The `innoRouterSceneHost` modifier is the preferred primary dispatcher: it
observes pending request tokens, claims work, dispatches through the
SwiftUI environment, and reports success back into the store.
`innoRouterSceneAnchor` mirrors that dispatch loop as a fallback only when no
explicit host is currently alive. If `openImmersiveSpace` returns
`.userCancelled` or `.error`,
the host emits a
`SceneEvent.rejected(.open(.immersive(...)), reason: .environmentReturnedFailure)`
and leaves the active scene inventory untouched. `currentScene` remains
a recency-ordered summary of that inventory, while `activeScenes`
exposes the full inventory. Calling `dismissImmersive()` without an active
immersive scene emits `.nothingActive` only when the entire inventory is empty.
If a window or volume remains active, it emits
`SceneEvent.rejected(.dismissImmersive, reason: .activeSceneMismatch)` instead.
`innoRouterSceneAnchor` still never emits public lifecycle events; it reconciles
inventory when the system opens or closes a scene outside the store's
explicit command path and can temporarily forward commands while the
preferred host scene is gone.

## Observing lifecycle through `events`

`SceneStore.events` is an `AsyncStream<SceneEvent<R>>` that mirrors
the `events` channel shipped by `NavigationStore` and `ModalStore`:

```swift skip doc-fragment
Task {
    for await event in sceneStore.events {
        analytics.record(event)
    }
}
```

The event taxonomy (`presented`, `dismissed`, `rejected`) is
deliberately minimal. Rejections carry the original `SceneIntent` so
subscribers can distinguish undeclared routes, declaration mismatches,
stale window handles, and environment failures without synthesising
placeholder routes.

## Ornaments on any platform

`View.innoRouterOrnament(_:content:)` attaches an ornament on
visionOS (delegating to SwiftUI's
`ornament(attachmentAnchor:contentAlignment:ornament:)`) and
degrades to a no-op on every other platform. That keeps call sites
unconditional:

```swift skip doc-fragment
ContentView()
    .innoRouterOrnament(OrnamentAnchor(anchor: .bottom, alignment: .center)) {
        ControlBar()
    }
```

`OrnamentAnchor` lives in `InnoRouterSpatial`, but remains serialisable and
testable on platforms that never materialise the visual effect.

## Composing with `FlowStore`

`SceneStore` is intentionally **not** composed into `FlowStore`.
`RouteStep` captures transitions inside a single scene (push / sheet
/ cover); spatial presentations are multi-scene events and would
break the `FlowStore` contract. Apps that need both simply own a
`FlowStore<R>` and a `SceneStore<R>` side-by-side — the `R` can be
the same route enum or two distinct enums, depending on whether the
spatial surface shares routes with the primary flow.
