# InnoRouter 6 examples

These examples are intentionally macro-first and compile against the single
public `InnoRouter` runtime product.

- `MacrosExample.swift` demonstrates the default host, native tabs and split
  view, presentations, and environment actions generated from `@Router`.
- `DeepLinkExample.swift` demonstrates fail-closed `@DeepLink` resolution in a
  macro-first host.
- `TabRestorationExample.swift` connects a Codable `@Router`, one store/catalog,
  file storage, the restoration driver, and an orphan-tolerant tab host. It
  requires the **unreleased 6.1 APIs**, not the published 6.0.0 package.

The matching files in `ExamplesSmoke/` are compiler-stable CI fixtures. The
independent package under `ConsumerSmoke/` proves the actual downstream product
boundary for the runtime, testing support, and inspector.

```bash
swift build --target InnoRouterMacrosExample
swift build --target InnoRouterDeepLinkExample
swift build --target InnoRouterTabRestorationExample
swift build --target InnoRouterMacroFirstSmoke
./scripts/external-consumer-smoke.sh
```

## Tab restoration (unreleased 6.1)

Copy `TabRestorationExample.swift` into a SwiftUI app using the current source
revision. After 6.1.0 is published, use that release or later. The file imports
only the public `InnoRouter` product; no internal modules or test tools are
required. Add this app entry point, or use the view in an existing app:

```swift skip app-entry-point
import Foundation
import SwiftUI

@main
struct RestorationDemoApp: App {
    private let snapshotURL = URL.applicationSupportDirectory
        .appending(path: "InnoRouterRestorationDemo/navigation.json")

    var body: some Scene {
        WindowGroup {
            TabRestorationUpgradeDemoView(snapshotURL: snapshotURL)
        }
    }
}
```

Use a dedicated demo path. The launcher has two explicit actions:

1. **Create previous-version demo** overwrites that file with an old
   `home`/`legacy` snapshot and then mounts the current `home`/`settings` host.
   Only use it with no other scene or driver writing the same file.
2. **Open saved session** opens the current file without replacing it. Select
   this after quitting and reopening the demo to exercise persistence.

On the first action, Home shows the saved `saved-home` detail, Settings is a
new empty stack, and the removed Legacy tab is hidden. Its saved subtree is
retained as an orphan; selection falls back from Legacy to Home. Select
Settings, choose Open detail, and await Save now's success message. Quit and
reopen, choose Open saved session, and confirm the Settings detail returns.
Automatic writes are also coalesced after navigation and flushed when the
scene becomes inactive; force-killing an app does not guarantee a final flush.

For ordinary app startup, use `TabRestorationExampleView(snapshotURL:)`
directly instead of the tutorial launcher. Retain one session per root and
use a stable, separate file per account or independently owned scene. Do not
open multiple windows against the demo's single file.

The result panel distinguishes no snapshot, applied, unchanged, rejected,
deferred, and operation failure. The example's `.fail` recovery leaves reset
and migration decisions to the application. A restore returning without an
error is not sufficient evidence of a commit. Automatic driver restore does
not return a partial-validation report; apps using `restorePartially` must
inspect both `report.topologyChanges` and `transition`.

Run the actual example's file persistence and upgrade tests with:

```bash
swift test --jobs 2 --no-parallel --filter TabRestorationExampleTests
```

These tests cover old-catalog reconciliation, navigation in the inserted tab,
save/reopen through a new session, missing files, and malformed-file
preservation. They do not replace native gesture or OS process-relaunch QA.

See the [tab restoration guide](../Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md)
for identity, schema migration, recovery, and lifecycle contracts.
