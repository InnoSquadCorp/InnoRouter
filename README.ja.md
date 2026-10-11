# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

マクロを中心とした SwiftUI の型安全なナビゲーション。1 つのルート enum、再帰的な状態ツリー、単一の変更権限で構成します。

現在の安定版は **7.0.0**、公開日は 2026 年 10 月 8 日です。タグのコミットは `33b0da7639105cfa8e6f5acffa3badb91b5e0254`。このガイドは同リリースを説明し、過去の候補版検証記録は元の範囲を保持します。

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## 要件とインストール

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

Package.swift の依存関係と製品の配列にそれぞれ追加します。`from:` は互換性のある 7.x 更新を許可します。固定する場合は `exact: "7.0.0"` を使います。通常のアプリは `InnoRouter` のみを import し、`InnoRouterTesting` と `InnoRouterInspector` は任意です。

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## 30 秒クイックスタート

host が store を所有します。`@EnvironmentRouter` はアクションを送信し、`@EnvironmentRouterState` は読み取り専用状態を監視します。どちらも対応する host の下で使います。外部 store は安定した所有境界で保持し、`body` 内で再生成しないでください。

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

## 状態、権限、エラーを投げる初期設定

`RouterState` は外部から読み取り専用です。`RouterStateDraft` を編集し、`try build(resourceBudget:)` で検証して `RouterPlan(state:)` を作成します。plan は正確な目標、`RouterAction` は増分変更を表し、`RouterStore` だけが commit します。`RouterScope` は部分ツリーの読み取りとアクション転送を担い、別 store は所有しません。

`RouterStore<AppRoute>()` と `AppRoute.makeRouterStore()` は非 throwing です。初期状態・経路・設定を渡す場合は `try` が必要です。外部 store の renderer には明示的な `hostDescriptor` が必要で、以下は標準 stack root の宣言です。初期設定でエラーを処理して復旧 UI を表示し、`try!` や無関係な空状態で隠さないでください。

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## 結果、ポリシー、キャンセル

リクエストは reduce → prepare → commit と進みます。適用された遷移は状態全体を一度代入し、revision を一度増やします。unchanged、rejected、deferred は候補を commit しません。`RouterOutcome` の 4 ケースを処理してください。以下は main actor 上で先ほどの `AppRoute` を使う断片です。

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

ポリシーは中断を挟んでも不変の候補を検査します。拒否、呼び出し元のキャンセル、古い準備、無効なアクションは確定状態を変えません。`RouterRequestKey` は `keepFirst` / `replacePending` を提供し、無関係なリクエストは FIFO です。待機数、timeout、延期に上限を設定します。`deferRequest` は実行レーンを解放し、明示的な rebase 以外の再開では revision を確認します。キャンセルに協調しないポリシーが遅れて返ってもキャンセルが優先します。`RouterRejectionReason` は overflow、timeout、期限切れ、キャンセルを区別します。

## タブ、分割表示、スコープの寿命

引数のない root に `@TabItem` を付け、通常の遷移先は同じ enum に置きます。`RouterTabHost` は独立した履歴を保持します。case の改名前に安定した ID を指定し、Codable ルート変更には別途 migration を用意します。入力のある tab/split host は `body` の外で `try` を使って作成します。`RouterSplitHost` と `RouterThreeColumnSplitHost` には安定した列宣言 ID が必要です。`RouterTabCatalog.hostDescriptor()` を使い、構造と意味は `replaceHost(with:descriptor:context:)` で原子的に変更します。部分ツリーの復元・置換で以前の scope 権限は失効するので再取得してください。`RouterHost(store:)` は非 throwing のまま `validationFailure` と復旧 UI を提供します。

独立した機能 enum は `@FeatureRoute` と `RouterFeatureHost` で合成します。子の `@EnvironmentRouter` と `@EnvironmentRouterState` も親 store のポリシー・キュー・revision・commit を共有します。機能は部分ツリー全体を所有し、親子のルート値が混在すると明示的に失敗します。window と immersive scene の所有権はアプリの合成 root に置きます。

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## ディープリンクと認証待ち

scheme と host をリテラルの許可リストで制限します。対応する `RouterHost` が `onOpenURL` を処理し、不正入力や未許可 origin は拒否します。例は example.com の HTTPS 製品 URL を受け付けます。`RouterLinkPipeline` は `RouterPlan` を生成し、認証ポリシーは部分移動せず目標全体を保留できます。`RouterPendingLinkSlot` は置換・キャンセル・再開を明示し、`RouterPendingLinkPersistenceDriver` はアプリが選んだ保存先に継続情報を保持します。遅い復元は新しい保留リンクを上書きしません。`inspectorCatalog: true` と `explainDeepLink(_:)` は任意の読み取り専用診断です。

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

## 型付きの表示結果

宣言、呼び出し側、表示先は同じルート型と対応 host を使います。以下は文脈を必要とする断片で、完成したアプリではありません。生成された request は両端の結果型を検査し、正確な presentation UUID と一度の完了要求が値を所有します。古い callback やキャンセルは置換先を閉じられません。操作による dismiss、キャンセル、拒否、値は別の結果です。表示の寿命を超えて完了権限を保持しないでください。

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

## 復元とナビゲーション履歴

`RouterRestorationDriver` と保存先を保持し、安定した root に `routerStateRestoration(_:)` を付けます。`RouterSnapshotCodec` をバージョン管理し、ルート/schema の migration と復元結果を処理します。タブ変更時は `RouterTabRestorationTopology`、`catalog.hostDescriptor(orphanPolicy: .preserveDormant)`、renderer で同じ catalog を使います。休止 branch は選択 renderer になれません。古い復元が新しい移動を上書きしないようにします。snapshot の既定上限は有限の暫定値です。増やす前に計測し、突然の終了時の最終保存は保証しないでください。

`RouterHistory` は exact plan と通常のポリシーで上限付きの前後移動と checkpoint を提供します。badge と presentation を保持し、scene は開閉しません。アカウント・文書の境界で `reset(sessionKey:)` を呼びます。reset または stop は中断された移動を無効にします。

snapshot の永続化には Codable ルートが必要で、payload/schema の migration はアプリが定義します。

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## シーン、システム連携、プラットフォーム対応

引数のない `@Scene(.window)` / `@Scene(.immersiveSpace)` を宣言し、対応 scene と並べて `RouterSceneDriver` を設置します。window UUID と `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle` を使い、visionOS では `RouterImmersiveSpaceScene` で native activation identity を渡します。各 scene は同じ store 内の部分ツリーを持ち、プラットフォームの availability は適用されます。`RouterPlatformCapabilities.current` は対応機能を示し、`RouterEvent.platformAdapted` は代替動作を通知します。`RouterUIKitBridge` / `RouterAppKitBridge` も同じ権限を使います。`RouterOpenURLIntentBuilder`、`RouterShortcutCatalog`、`routerHandoff`、`continueRouterHandoff` は URL 契約を共有し、Handoff は HTTP(S) のみ受け付けます。

## テスト、Inspector、可観測性

`RouterTestStore` は host なしで本番の reducer とポリシーを実行し、`RouterActionSequence` は context を保持します。`RouterInspectorRecorder` は payload を除いた上限付き timeline、diff、import/export、純粋 reducer replay を提供し、live store は変更しません。import の既定値は 8 MiB、5,000 件です。`RouterObservability` は payload なしのログ/signpost を提供し、analytics は送信しません。

`RouterScenarioRecorder` は実行制御を記録し、`RouterScenarioRunner` はキャンセルと延期も再現します。fixture v9 は navigation-only v8 に対応し、より古い・未知の形式は再収集が必要です。raw fixture にはアプリ payload があり、明示的な export が必要です。`RouterScenarioSourceGenerator.generateFiles` は開発者が定義した期待値を要求します。Inspector は英語と 15 の翻訳に対応し、README の 7 言語とは別です。

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## 移行と過去のドキュメント

6.x → 7 は破壊的変更です。読み取り専用状態 draft、throwing 初期設定、固定 host 宣言、有限予算、authorization generation、寿命に結び付く結果を確認してください。5.x からは独立 store/intent と廃止された個別製品も置き換えます。過去の API を現在のアプリにコピーしないでください。アーカイブ索引には過去の全 7 言語を残しています。

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## 検証と貢献

7 つのクイックスタートは API 例と契約範囲を共有します。静的検査は Swift コンパイル、DocC 表示、native scene 動作、人間による翻訳校閲を保証しません。merge 前に Apple toolchain の gate を実行してください。`--no-parallel` は同期復元 test double による cooperative pool 枯渇を防ぎます。同じ scratch ディレクトリで SwiftPM build を同時実行しないでください。

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## ライセンスと支援

MIT ライセンス。貢献、不具合報告、ドキュメント修正を歓迎します。

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
