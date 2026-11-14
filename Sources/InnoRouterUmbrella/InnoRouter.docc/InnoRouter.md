# InnoRouter

Macro-first typed navigation for SwiftUI.

## Release and requirements

This catalog describes stable InnoRouter **7.0.0**. Use Swift 6.3+ with
iOS/iPadOS/Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, or visionOS 2+.
Apps import the `InnoRouter` product; `InnoRouterTesting` and
`InnoRouterInspector` are optional. Platform-specific scenes and presentations
retain their availability constraints. Read <doc:Migrating-To-InnoRouter-7>
when moving from 6.x; older release notes remain historical evidence.

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

### Added in 7.1.0

Version 7.1.0 adds opt-in behaviors and conveniences; the defaults keep the
7.0 behavior.

- Set `RouterStoreConfiguration.dispatchTiming` to `.immediateWhenIdle` to let
  a fire-and-forget request made through `RouterActions` (`router.go(_:)` and
  the other `@EnvironmentRouter` methods) commit before the call returns when
  nothing is pending, so a surrounding `withAnimation` applies to the
  navigation change. The Store's and scopes' own `dispatch` methods and the
  hosts' native bindings keep committing on a later turn.
- Create a `RouterRestorationDriver` with `initialRestorePrecedence: .snapshot`
  to keep the Store from committing anything until the initial restore has
  run, so navigation a view requests while the snapshot loads cannot displace
  the previous session. <doc:Restoring-Tab-Navigation> describes what happens
  to requests made meanwhile.
- `RouterTabHost(AppRoute.self)` builds the tab host of an `@Router` enum
  without `try`. `validationFailure` reports a hand-written catalog that is
  invalid.
- `makeRouterHostStore()`, `makeRouterHostStore(configuration:)`, and
  `makeRouterTabHostStore(initial:badges:orphanPolicy:configuration:)` create
  Stores already declared for `RouterHost(store:)` and `RouterTabHost(store:)`.

Deep-link admission is stricter: origins match byte for byte after folding
ASCII case only, user information is rejected in any form, and percent-encoding
that is not valid UTF-8 is never accepted as a value.

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
- `RouterRestorationPrecedence` (7.1.0+)
- `RouterDispatchTiming` (7.1.0+)
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
