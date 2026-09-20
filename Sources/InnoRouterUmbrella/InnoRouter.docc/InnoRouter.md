# InnoRouter

Macro-first typed navigation for SwiftUI.

## Overview

Declare one route enum with `@Router`. The generated conformance unlocks one
`RouterStore<Route>`, one recursive `RouterState<Route>`, and one
`RouterAction<Route>` request vocabulary.

`RouterHost`, `RouterTabHost`, and `RouterSplitHost` render native SwiftUI
containers over that authority. `RouterPlan<Route>` represents an exact target
shared by deep links, restoration, and transactions.

The published 6.0.0 package supports typed presentations and scenes, native tab
and split hosts, deep-link admission, snapshot restoration, bounded scheduling,
and optional testing and Inspector tools. Applications choose their storage,
recovery, and policy behavior explicitly while the store remains the single
navigation authority.

### Unreleased 6.1 additions

The current source adds explicit tab-topology restoration for apps whose tab
catalog changes between launches. `RouterTabRestorationTopology` adds missing
current scopes while preserving saved paths and orphaned branches. Partial
restoration reports describe structural changes through `topologyChanges`.
These APIs are not included in the published 6.0.0 package.

Read <doc:Restoring-Tab-Navigation> for catalog ownership, outcome handling,
and a complete, compiled example with file persistence.

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
- `RouterTabRestorationTopology` (unreleased 6.1)
- `RouterTabRestorationChange` (unreleased 6.1)
- `RouterPartialRestorationReport`
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
- <doc:Restoring-Tab-Navigation>
