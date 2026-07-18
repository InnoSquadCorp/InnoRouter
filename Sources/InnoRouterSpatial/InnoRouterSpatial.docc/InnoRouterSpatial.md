# InnoRouterSpatial

Macro-first scene routing for visionOS windows, volumes, immersive spaces, and
ornaments.

## Overview

`InnoRouterSpatial` keeps multi-scene presentation outside the default
`InnoRouter` umbrella. Add the product explicitly and import it only in the
targets that own spatial scene declarations:

```swift skip package-manifest-fragment
.product(name: "InnoRouterSpatial", package: "InnoRouter")
```

```swift skip import-fragment
import InnoRouterSpatial
```

Start by declaring the complete app scene inventory with `@SceneRouter` and
one `@Scene` per case. Install the generated `Route.scenes` value in
`App.body`, then open and dismiss scenes from descendants through
`@EnvironmentSceneRouter`.

```swift skip doc-fragment
@SceneRouter
enum AppScene {
    @Scene(.window)
    case main

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main: MainView()
        case .theatre: TheatreView()
        }
    }
}

@main
struct MyApp: App {
    var body: some Scene {
        AppScene.scenes
    }
}
```

This module owns:

- `@SceneRouter`, `@Scene`, and `SpatialSceneStyle`
- generated `Route.scenes` composition on visionOS
- `SceneRouterActions` and `EnvironmentSceneRouter`
- `ScenePresentation`, `VolumetricSize`, and `ImmersiveStyle`
- `SceneDeclaration` and `SceneRegistry`
- `SceneStore`, `SceneIntent`, `SceneEvent`, and `SceneRejectionReason`
- `innoRouterSceneHost` and `innoRouterSceneAnchor` on visionOS
- `OrnamentAnchor` and `innoRouterOrnament`

The macro owns the store, registry, host, and anchors for the common path. Use
those runtime types directly only when an application boundary must own scene
state, observe `SceneStore.events`, inject custom lifecycle wiring, or compose
declarations dynamically outside the generated inventory.

## Platform support

| Capability | iOS | iPadOS | macOS | tvOS | watchOS | visionOS |
|---|---|---|---|---|---|---|
| `@SceneRouter` route and destination declaration | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Generated `Route.scenes` and scene dispatch | — | — | — | — | — | ✅ |
| `EnvironmentSceneRouter` facade | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `SceneStore`, `innoRouterSceneHost`, `innoRouterSceneAnchor` | — | — | — | — | — | ✅ |
| `innoRouterOrnament` | no-op | no-op | no-op | no-op | no-op | ✅ |

The cross-platform action facade lets shared view code compile. On visionOS,
invoking it without a generated or manually composed authority follows
`EnvironmentMissingPolicy`. On every other platform an authority can never
be published, so invocation always logs and degrades to a no-op regardless
of the configured policy; it does not emulate spatial scenes on another
platform.

## Topics

### Essentials

- <doc:Tutorial-VisionOSScenes>
