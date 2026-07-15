# visionOS: macro-first app scenes

@Metadata {
  @PageKind(article)
}

Declare windows, volumetric windows, and immersive spaces in one route enum.
Install the generated scene tree once, then use route-typed environment actions
from the views rendered by that tree.

## Why scenes use a separate router

visionOS app scenes are not stack or modal destinations:

- a regular window uses `WindowGroup(id:for:)`
- a volumetric window adds `windowStyle(.volumetric)` and a physical size
- an immersive space uses `ImmersiveSpace(id:)` and an immersion style

Their SwiftUI open and dismiss actions are available only inside a scene's
view hierarchy. `@SceneRouter` generates that scene hierarchy and publishes one
route-typed authority, while `@EnvironmentSceneRouter` keeps feature views
independent of the underlying SwiftUI action chosen for each route.

## 1. Declare the scene inventory

Add the `InnoRouterSpatial` product to the visionOS app target and import it
explicitly:

```swift skip package-manifest-fragment
.product(name: "InnoRouterSpatial", package: "InnoRouter")
```

```swift skip doc-fragment
import SwiftUI
import InnoRouter
import InnoRouterSpatial

@SceneRouter
enum AppScene {
    @Scene(.window)
    case main

    @Scene(
        .volumetric(width: 0.6, height: 0.4, depth: 0.4),
        id: "model"
    )
    case model

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main:
            MainView()
        case .model:
            ModelView()
        case .theatre:
            TheatreView()
        }
    }
}
```

Every case is parameterless and has exactly one `@Scene`. The style carries
declaration metadata rather than request-time options:

- `.window` creates a regular value-based window
- `.volumetric(width:height:depth:)` creates a volumetric window whose positive
  finite dimensions are measured in metres
- `.immersive(style:)` creates an immersive space

An explicit `id` is optional and defaults to the case name. Supply one only
when the Swift case may be renamed while the system scene identifier must stay
stable.

The first case becomes the primary dispatcher host. Put a window or volume
first for the normal launch path; all later cases become lifecycle anchors.
The macro diagnoses missing annotations, associated values, duplicate IDs,
conditional inventories, invalid sizes, and conflicting generated members at
compile time.

## 2. Install the generated scene tree

Use the generated static `scenes` property as the app's scene body:

```swift skip doc-fragment
@main
struct MyApp: App {
    var body: some Scene {
        AppScene.scenes
    }
}
```

That single line owns the common composition:

- one `SceneStore<AppScene>`
- one `SceneRegistry<AppScene>` built from the annotations
- a primary `innoRouterSceneHost` on the first scene
- an `innoRouterSceneAnchor` on every later scene
- the matching `WindowGroup`, volumetric style and size, or `ImmersiveSpace`

Do not add a second store, host, or anchor around generated destinations. The
generated tree is the routing authority for that route type.

### Immersive-first launch

An immersive scene cannot normally dispatch until the system opens it. If the
product truly launches directly into immersion, configure the app scene
manifest with
`UIApplicationPreferredDefaultSceneSessionRole` set to
`UISceneSessionRoleImmersiveSpaceApplication`, configure
`UISceneInitialImmersionStyle` when needed, and acknowledge that external
contract in source:

```swift skip doc-fragment
@SceneRouter(immersiveLaunch: true)
enum ImmersiveAppScene {
    @Scene(.immersive(style: .full))
    case experience

    var destination: some View {
        ExperienceView()
    }
}
```

The macro cannot inspect `Info.plist`; the argument only suppresses the
immersive-primary warning after the application has configured that launch
contract. It warns when the acknowledgement is unnecessary for a window- or
volume-first router.

## 3. Open and dismiss scenes from views

Read the nearest matching scene router just as stack and modal views read
`@EnvironmentRouter`:

```swift skip doc-fragment
struct SceneControls: View {
    @EnvironmentSceneRouter(AppScene.self) private var scenes
    @State private var modelWindow: ScenePresentation<AppScene>?

    var body: some View {
        VStack {
            Button("Open model") {
                modelWindow = scenes.open(.model)
            }

            Button("Close model") {
                if let modelWindow {
                    scenes.dismissWindow(modelWindow)
                }
            }

            Button("Enter theatre") {
                scenes.open(.theatre)
            }

            Button("Leave theatre") {
                scenes.dismissImmersive()
            }
        }
    }
}
```

`open(_:)` reads the route's kind, ID, volumetric size, and immersive style
from the generated registry. It returns a request handle for a window or
volume, or an immersive presentation value; it is not a promise that the
system completed the presentation. Use `dismissWindow(_:)` with a retained
window or volume handle and `dismissImmersive()` for the active immersive
space.

Environment resolution is lazy. Merely rendering a view outside the generated
tree does not report an error; invoking an action without the matching route
authority applies `EnvironmentMissingPolicy`. The default fails loudly and
points back to installing `AppScene.scenes`. A deliberately degradable preview
or shared cross-platform view can opt into `.logAndDegrade` at its boundary.

## Advanced: own the store and registry manually

Use manual composition when the application must retain the store, observe
scene events, inject a registry from another boundary, or control host and
anchor placement directly. This is the plain Swift equivalent of the generated
tree:

```swift skip doc-fragment
import SwiftUI
import InnoRouterSpatial

enum SpatialRoute: Route {
    case main
    case theatre
}

private let spatialScenes = SceneRegistry<SpatialRoute>(
    .window(.main, id: "main"),
    .immersive(.theatre, id: "theatre", style: .mixed)
)

@main
struct ManualSpatialApp: App {
    @State private var sceneStore = SceneStore<SpatialRoute>()

    var body: some Scene {
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

Attach exactly one host per store and one anchor to every non-host scene:

| Scene declaration | `innoRouterSceneHost` | `innoRouterSceneAnchor` |
|---|---|---|
| Primary `WindowGroup` or volume | Exactly once | Never on the same scene |
| Secondary `WindowGroup` or volume | No | Exactly once |
| `ImmersiveSpace` | No, unless it is the configured immersive-first host | Exactly once otherwise |

The host is the preferred dispatcher. Anchors reconcile system-driven
appear/disappear lifecycle and can temporarily dispatch for their own
declaration if the host is gone. They reject cross-scene opens they cannot
perform instead of pretending success. Value-based windows use the `UUID`
provided by `WindowGroup`; immersive spaces use route-only host or anchor
overloads.

### Observe manual scene lifecycle

Manual ownership exposes `SceneStore.events`. Capture the stream before
starting its lifecycle task so observation is registered before the next
request:

```swift skip doc-fragment
let events = sceneStore.events
let observationTask = Task { @MainActor in
    for await event in events {
        analytics.record(event)
    }
}
```

Scene lifecycle events are `presented`, `dismissed`, and `rejected`; a duplicate
primary host additionally emits `hostRegistrationRejected`. Rejections retain
the original `SceneIntent` and distinguish undeclared routes, declaration
mismatches, stale window handles, fallback-dispatch limits, and
environment-returned failures such as user cancellation. The generated macro
keeps its store private; promote to this manual shape when direct event
observation is a requirement.

## Ornaments on any platform

`View.innoRouterOrnament(_:content:)` attaches a SwiftUI ornament on visionOS
and is a no-op on every other supported platform, so a shared call site can
remain unconditional:

```swift skip doc-fragment
ContentView()
    .innoRouterOrnament(
        OrnamentAnchor(anchor: .bottom, alignment: .center)
    ) {
        ControlBar()
    }
```

`OrnamentAnchor` remains serializable and testable even where the visual effect
does not materialize.

## Compose beside in-scene routing

`SceneStore` is intentionally not part of `FlowStore`. `RouteStep` describes
push, sheet, and cover transitions inside one scene, while spatial routing
opens or dismisses app-level scenes. An app can use `@SceneRouter` for its app
scene inventory and a separate `@Router` host inside any generated scene. In
the manual path it can own `SceneStore<R>` and `FlowStore<R>` side by side; the
route types may be shared or distinct according to the product boundary.
