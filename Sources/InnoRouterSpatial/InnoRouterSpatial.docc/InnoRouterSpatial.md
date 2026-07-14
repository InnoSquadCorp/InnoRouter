# InnoRouterSpatial

Opt-in scene routing for visionOS windows, volumes, immersive spaces, and ornaments.

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

This module owns:

- `ScenePresentation`, `VolumetricSize`, and `ImmersiveStyle`
- `SceneDeclaration` and `SceneRegistry`
- `SceneStore`, `SceneIntent`, `SceneEvent`, and `SceneRejectionReason`
- `innoRouterSceneHost` and `innoRouterSceneAnchor` on visionOS
- `OrnamentAnchor` and `innoRouterOrnament`

The store owns desired scene state and the view modifiers bridge that authority
to SwiftUI environment actions. A registry validates every route against the
scene declarations owned by the app.

## Platform support

| Capability | iOS | iPadOS | macOS | tvOS | watchOS | visionOS |
|---|---|---|---|---|---|---|
| Scene declarations and presentation metadata | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `SceneStore`, `innoRouterSceneHost`, `innoRouterSceneAnchor` | — | — | — | — | — | ✅ |
| `innoRouterOrnament` | no-op | no-op | no-op | no-op | no-op | ✅ |

## Topics

### Essentials

- <doc:Tutorial-VisionOSScenes>
