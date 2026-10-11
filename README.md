# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

Macro-first, typed navigation for SwiftUI. One route enum, one recursive state tree, one mutable authority.

Current stable release: **7.0.0**, published October 8, 2026. The release tag points to `33b0da7639105cfa8e6f5acffa3badb91b5e0254`. This guide describes that release; historical candidate reports retain their original scope.

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## Requirements and installation

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

Add the package dependency and the product to the corresponding arrays in your Package.swift. `from:` allows compatible 7.x updates; use `exact: "7.0.0"` for an exact baseline. Normal apps import only `InnoRouter`. Optional products: `InnoRouterTesting` and `InnoRouterInspector`.

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## 30-second quick start

The host owns the store. `@EnvironmentRouter` sends actions; `@EnvironmentRouterState` observes read-only UI state. These wrappers require a matching host. Keep a supplied store at a stable application boundary, never recreate it in `body`.

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case settings
    case detail(id: String)

    var destination: some View {
        switch self {
        case .settings: Text("Settings")
        case .detail(let id): Text("Detail \(id)")
        }
    }
}

struct HomeView: View {
    @EnvironmentRouter(AppRoute.self) private var router
    @EnvironmentRouterState(AppRoute.self) private var routerState

    var body: some View {
        Button("Open detail") { router.go(.detail(id: "42")) }
            .disabled(routerState.presentation != nil)
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) { HomeView() }
    }
}
```

## One runtime model

`RouterState` is externally read-only; edit a `RouterStateDraft` and call `try build(resourceBudget:)` before forming a `RouterPlan(state:)`. A plan describes an exact target. `RouterAction` describes incremental changes. Only `RouterStore` commits navigation. `RouterScope` is a read-only subtree projection and action forwarder, not another store.

`RouterStore<AppRoute>()` and `AppRoute.makeRouterStore()` remain nonthrowing. Initial state, paths, and configuration require `try`. A supplied-store renderer needs an explicit `hostDescriptor`; the example declares the default stack root. Handle setup errors in app initialization and render recovery UI. Do not hide them with `try!` or an unrelated empty state.

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## Outcomes, policies, and cancellation

Requests follow reduce → prepare → commit. An applied transition assigns the complete state and increments the revision once. Unchanged, rejected, and deferred requests do not commit a candidate. Handle all four `RouterOutcome` cases. This fragment runs on the main actor and reuses `AppRoute` above.

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

Policies inspect immutable candidates across suspension. Rejection, caller cancellation, stale preparation, and invalid actions leave committed state unchanged. `RouterRequestKey` supports `keepFirst` / `replacePending`; unrelated requests remain FIFO. Bound pending requests, policy timeouts, and deferrals explicitly. A `deferRequest` releases the execution lane; resumption checks revision unless explicitly rebased. Cancellation still wins against a late non-cooperative policy. `RouterRejectionReason` distinguishes overflow, timeout, expiry, and cancellation.

## Tabs, split views, and scope lifetimes

Mark parameterless roots with `@TabItem`; keep ordinary destinations in the same enum. `RouterTabHost` preserves independent branch histories. Use explicit stable tab IDs before renaming cases; Codable route changes still need migration. Construct input-bearing tab/split hosts with `try` outside nonthrowing `body`. `RouterSplitHost` and `RouterThreeColumnSplitHost` require stable column declaration IDs. A `RouterTabCatalog` supplies `hostDescriptor()`; change root meaning or topology atomically with `replaceHost(with:descriptor:context:)`. Restoring or replacing an owned subtree expires its old scope authority; reacquire scopes after replacement. `RouterHost(store:)` remains nonthrowing and exposes `validationFailure` plus recovery UI.

Compose independent feature enums with `@FeatureRoute` and `RouterFeatureHost`. Child `@EnvironmentRouter` and `@EnvironmentRouterState` forward through the parent store’s policies, queue, revision, and commit. The feature must own its complete subtree; mixed parent/child values fail explicitly. Window and immersive-scene ownership stays at the app composition root.

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## Deep links and pending authentication

Use literal scheme and host allowlists. A matching `RouterHost` handles `onOpenURL`; malformed or unapproved origins fail closed. The example accepts HTTPS product URLs at example.com. `RouterLinkPipeline` promotes a match to `RouterPlan`; policies can retain the whole target without partial navigation. `RouterPendingLinkSlot` makes replacement, cancellation, and resume explicit. `RouterPendingLinkPersistenceDriver` persists an app-selected continuation; a slow restore cannot overwrite a newer pending link. `inspectorCatalog: true` and `explainDeepLink(_:)` enable opt-in read-only diagnostics.

```swift compile
import SwiftUI
import InnoRouter

@Router(deepLinkSchemes: ["https"], deepLinkHosts: ["example.com"])
enum LinkedRoute {
    @DeepLink("/products/:id")
    case product(id: String)

    var destination: some View {
        switch self {
        case .product(let id): Text("Product \(id)")
        }
    }
}
```

## Typed presentation results

The declaration, caller, and presented destination must share the same route type and host. This is a contextual fragment, not a standalone app. A generated request checks the result type at both ends. The presentation UUID and one completion request own the value. Stale callbacks and caller cancellation cannot dismiss a replacement. Interactive dismissal, cancellation, rejection, and a returned value remain distinct. Do not retain a completion authority beyond its presentation lifetime.

```swift skip contextual-fragment
@Router
enum SettingsRoute {
    @PresentationResult(Bool.self)
    case settings
    var destination: some View { Text("Settings") }
}

// In a view under a matching SettingsRoute host:
// @EnvironmentRouter(SettingsRoute.self) private var router
let request = SettingsRoute.Presentation.settings
switch await router.present(request) {
case .value(let saved): print(saved)
case .dismissed: break
case .cancelled: break
case .rejected(let reason): print(reason)
}
// In the presented destination, using its matching environment router:
try await router.finishPresentation(request, returning: true)
```

## Restoration and navigation history

Retain `RouterRestorationDriver` with app-selected storage and attach `routerStateRestoration(_:)` to a stable root. Version snapshots with `RouterSnapshotCodec`; define migrations for route/schema changes and inspect restore outcomes. For changing tabs use one catalog for `RouterTabRestorationTopology`, `catalog.hostDescriptor(orphanPolicy: .preserveDormant)`, and the renderer. Dormant branches cannot become selected renderers. Stale restoration must not overwrite newer navigation. Snapshot limits are finite provisional defaults: measure your app before increasing budgets; abrupt termination does not guarantee a final save.

`RouterHistory` provides bounded back/forward and checkpoints through exact plans and normal policies. It preserves badges and presentations and never opens or closes scenes. Reset with `reset(sessionKey:)` at account/document boundaries; reset or stop invalidates suspended moves.

Snapshot persistence requires Codable routes; application payload/schema migrations remain your responsibility.

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## Scenes, system integration, and platform adaptation

Declare parameterless `@Scene(.window)` / `@Scene(.immersiveSpace)` routes and install `RouterSceneDriver` beside matching app scene declarations. Use window UUID identity and `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle` callbacks. On visionOS, `RouterImmersiveSpaceScene` carries native activation identity. Each scene has its own subtree in the same store; platform availability still applies. `RouterPlatformCapabilities.current` describes support and `RouterEvent.platformAdapted` reports fallbacks. `RouterUIKitBridge` / `RouterAppKitBridge` adopt the same authority. `RouterOpenURLIntentBuilder`, `RouterShortcutCatalog`, `routerHandoff`, and `continueRouterHandoff` share the URL contract; Handoff accepts only HTTP(S).

## Testing, Inspector, and observability

`RouterTestStore` runs the production reducer and policies without a host. `RouterActionSequence` preserves transition context. `RouterInspectorRecorder` provides bounded, payload-redacted timelines, state diffs, import/export, and pure-reducer replay; replay does not mutate the live store. Import defaults are 8 MiB and 5,000 entries. `RouterObservability` adds payload-free logging/signposts without transmitting analytics.

`RouterScenarioRecorder` records execution controls; `RouterScenarioRunner` replays them, including cancellation and deferral. Fixture format v9 supports navigation-only v8; older/unknown formats need recapture. Raw fixtures contain app payloads and require explicit export. `RouterScenarioSourceGenerator.generateFiles` requires developer-supplied expectations before generating tests. Inspector supports English plus 15 translations; that UI localization is separate from the seven README languages.

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## Migration and historical documentation

6.x → 7 is a breaking migration: read-only state drafts, throwing setup, frozen host declarations, finite resource budgets, authorization generations, and lifetime-bound results. 5.x consumers must also replace independent stores/intents and removed granular products. Do not copy archived APIs into a current app. All seven historical translations remain linked in the archive index.

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## Validation and contributing

The seven quick starts share API snippets and contract coverage. Static checks do not establish Swift compilation, DocC rendering, native scene behavior, or human translation review. Run Apple-toolchain gates before merging. `--no-parallel` avoids cooperative-pool starvation from synchronous restoration test doubles. Never run simultaneous SwiftPM builds in one scratch directory.

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## License and support

MIT. Contributions, issue reports, and documentation corrections are welcome.

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
