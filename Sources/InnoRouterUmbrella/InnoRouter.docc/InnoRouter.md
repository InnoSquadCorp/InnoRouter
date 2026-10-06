# InnoRouter

Macro-first typed navigation for SwiftUI.

## Overview

Declare one route enum with `@Router`. The generated conformance unlocks one
`RouterStore<Route>`, one recursive `RouterState<Route>`, and one
`RouterAction<Route>` request vocabulary.

`RouterHost`, `RouterTabHost`, and `RouterSplitHost` render native SwiftUI
containers over that authority. `RouterPlan<Route>` represents an exact target
shared by deep links, restoration, and transactions.

InnoRouter supports typed presentations and scenes, native tab
and split hosts, deep-link admission, snapshot restoration, bounded scheduling,
and optional testing and Inspector tools. Applications choose their storage,
recovery, and policy behavior explicitly while the store remains the single
navigation authority.

### Added in 6.1.0

Version 6.1.0 adds explicit tab-topology restoration for apps whose tab
catalog changes between launches. `RouterTabRestorationTopology` adds missing
current scopes while preserving saved paths and orphaned branches. Partial
restoration reports describe structural changes through `topologyChanges`.
It also added opt-in snapshot byte limits, automatic partial validation,
and explicit `@TabItem` identifiers while preserving the 6.0 defaults at that
time. In 7.0, legacy snapshot codecs and file storage have finite provisional
defaults. Codec JSON depth, token and duplicate-key preflight also runs before
typed decoding and after every migration. Use measured finite overrides when
needed; an explicit nil opt-out is excluded from the bounded-decoding guarantee.

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
- `RouterTabRestorationTopology` (6.1.0+)
- `RouterTabRestorationChange` (6.1.0+)
- `RouterPartialRestorationReport`
- `RouterFileSnapshotStorage`
- `RouterTabCatalog`
- `RouterSceneCatalog`

### System integration

- `RouterSceneDriver`
- `RouterImmersiveSpaceScene` (visionOS)
- `RouterOpenURLIntentBuilder`
- `RouterShortcutCatalog`
- `RouterObservability`
- `RouterHandoffConfiguration`
- `RouterUIKitBridge`
- `RouterAppKitBridge`

## Migration

- <doc:Migrating-To-InnoRouter-7>
- <doc:Migrating-To-InnoRouter-6>
- <doc:Restoring-Tab-Navigation>
