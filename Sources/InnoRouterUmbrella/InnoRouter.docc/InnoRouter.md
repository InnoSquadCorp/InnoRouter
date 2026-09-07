# InnoRouter

Macro-first typed navigation for SwiftUI.

## Overview

Declare one route enum with `@Router`. The generated conformance unlocks one
`RouterStore<Route>`, one recursive `RouterState<Route>`, and one
`RouterAction<Route>` request vocabulary.

`RouterHost`, `RouterTabHost`, and `RouterSplitHost` render native SwiftUI
containers over that authority. `RouterPlan<Route>` represents an exact target
shared by deep links, restoration, and transactions.

The first 6.0 release candidate also includes the planned 6.1–6.3 capability sets:
stable generated tab identities, `@PresentationResult`, `@Scene`, native
presentation options, FIFO scheduling, semantic transition context, App Intent
and Handoff bridges, UIKit/AppKit hosting bridges, macro-first state reading,
pending-link continuation, opt-in restoration, developer-session playback,
payload-safe observability, shortcut catalogs, scene-local navigation,
two-/three-column split state, idempotent and coalesced requests, deferred
policies, native presentation/tab metadata, durable pending links, and
Inspector investigation bookmarks and breakpoints. The final hardening set
adds bounded request/deferral admission, policy timeouts, Inspector import
preflight, throwing manual tab/scene catalogs, and Mac Catalyst interface
validation. Instruments signposts, typed snapshot migrations, redacted support
bundles, and deterministic test action sequences complete the release
diagnostics and reproduction path without adding another navigation authority.

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case detail(id: String)

    var destination: some View {
        switch self {
        case .detail(let id):
            Text("Detail \(id)")
        }
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) {
            Text("Home")
        }
    }
}
```

## API overview

### Runtime

- `RouterStore`
- `RouterState`
- `RouterAction`
- `RouterPlan`
- `RouterPlanBuilder`
- `RouterSnapshotCodec`
- `RouterSnapshotMigration`
- `InnoRouterVersion`
- `EnvironmentRouter`
- `EnvironmentRouterState`
- `RouterStateReader`
- `RouterHost`
- `RouterTabHost`
- `RouterSplitHost`
- `RouterThreeColumnSplitHost`
- `RouterWindowHost`
- `RouterImmersiveSpaceHost`
- `RouterPendingLinkSlot`
- `RouterPendingLinkPersistenceDriver`
- `RouterRestorationDriver`
- `RouterFileSnapshotStorage`
- `RouterTabCatalog`
- `RouterSceneCatalog`

### System integration

- `RouterSceneDriver`
- `RouterOpenURLIntentBuilder`
- `RouterShortcutCatalog`
- `RouterObservability`
- `RouterHandoffConfiguration`
- `RouterUIKitBridge`
- `RouterAppKitBridge`

## Migration

- <doc:Migrating-To-InnoRouter-6>
