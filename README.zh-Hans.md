# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

以宏为核心的 SwiftUI 类型安全导航：一个路由枚举、一棵递归状态树、一个可变状态管理者。

当前稳定版为 **7.0.0**，发布于 2026 年 10 月 8 日。标签指向 `33b0da7639105cfa8e6f5acffa3badb91b5e0254`。本指南描述该版本；历史候选版报告仍保留原有验证范围。

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## 要求与安装

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

将依赖和产品分别加入 Package.swift 对应的数组。`from:` 允许兼容的 7.x 更新；精确固定版本请用 `exact: "7.0.0"`。普通应用只需导入 `InnoRouter`。可选产品为 `InnoRouterTesting` 和 `InnoRouterInspector`。

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## 30 秒快速开始

host 默认拥有 store。`@EnvironmentRouter` 发送动作，`@EnvironmentRouterState` 观察只读 UI 状态；两者必须位于匹配的 host 下。外部 store 应由应用的稳定边界持有，不要在 `body` 中反复创建。

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

## 状态、权限与可抛错的初始化

`RouterState` 对外只读。修改 `RouterStateDraft`，调用 `try build(resourceBudget:)` 验证后创建 `RouterPlan(state:)`。plan 表示精确目标，`RouterAction` 表示增量变更，只有 `RouterStore` 能提交导航。`RouterScope` 是子树的只读投影和动作转发器，不是另一个 store。

`RouterStore<AppRoute>()` 和 `AppRoute.makeRouterStore()` 不抛错；提供初始状态、路径或配置时必须使用 `try`。外部 store 的 renderer 需要明确的 `hostDescriptor`；下面声明默认 stack 根节点。在应用初始化阶段处理错误并显示恢复界面，不要用 `try!` 或无关空状态隐藏失败。

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## 结果、策略与取消

请求依次经过 reduce → prepare → commit。已应用的转换一次性赋值完整状态，并将 revision 增加一次。unchanged、rejected、deferred 不提交候选状态。请处理四种 `RouterOutcome`。下面的片段在 main actor 上运行，复用上面的 `AppRoute`。

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

策略在挂起前后检查不可变候选状态。拒绝、调用者取消、过期准备或无效动作不改变已提交状态。`RouterRequestKey` 支持 `keepFirst` / `replacePending`；无关请求仍按 FIFO 执行。明确限制队列、策略超时和延后请求。`deferRequest` 释放执行通道；恢复时检查 revision，除非显式 rebase。即使策略不配合取消且很晚才返回，取消仍优先。`RouterRejectionReason` 区分溢出、超时、过期与取消。

## 标签页、分栏与作用域生命周期

用 `@TabItem` 标记无参数根路由，普通目标保留在同一枚举中。`RouterTabHost` 维护独立分支历史。重命名 case 前先指定稳定 ID；Codable 路由变更仍需迁移。带输入的 tab/split host 要在不抛错的 `body` 外通过 `try` 创建。`RouterSplitHost`、`RouterThreeColumnSplitHost` 需要稳定的列声明 ID。用 `RouterTabCatalog.hostDescriptor()` 固定含义，通过 `replaceHost(with:descriptor:context:)` 原子替换拓扑与含义。恢复或替换子树会使旧 scope 权限失效，之后应重新获取。`RouterHost(store:)` 保持不抛错，通过 `validationFailure` 和恢复 UI 报告问题。

用 `@FeatureRoute` 和 `RouterFeatureHost` 组合独立功能枚举。子功能的 `@EnvironmentRouter`、`@EnvironmentRouterState` 共用父 store 的策略、队列、revision 和 commit。功能必须拥有完整子树，混合父子路由值会明确失败。窗口和沉浸式 scene 仍由应用组合根管理。

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## 深层链接与待完成的认证

scheme 和 host 使用字面量允许列表。匹配的 `RouterHost` 处理 `onOpenURL`，畸形输入和未授权来源默认拒绝。示例接受 example.com 的 HTTPS 产品 URL。`RouterLinkPipeline` 将匹配转换为 `RouterPlan`，认证策略可保留完整目标而不进行部分导航。`RouterPendingLinkSlot` 明确管理替换、取消、恢复；`RouterPendingLinkPersistenceDriver` 在应用选择的存储中持久化后续操作，慢速恢复不会覆盖更新的待处理链接。`inspectorCatalog: true` 和 `explainDeepLink(_:)` 可启用只读诊断。

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

## 带类型的展示结果

声明、调用者和被展示的目标必须使用相同路由类型及匹配 host。下面是依赖上下文的片段，不是完整应用。生成的请求在两端检查结果类型，由准确的 presentation UUID 和一次完成请求拥有结果。过期回调或调用者取消不能关闭替代界面。交互关闭、取消、拒绝和返回值是不同结果。不要在 presentation 生命周期结束后继续持有完成权限。

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

## 恢复与导航历史

稳定持有 `RouterRestorationDriver` 及应用选择的存储，在根节点附加 `routerStateRestoration(_:)`。为 `RouterSnapshotCodec` 设置版本，迁移路由/schema 变更并检查恢复结果。标签目录变化时，`RouterTabRestorationTopology`、`catalog.hostDescriptor(orphanPolicy: .preserveDormant)` 和 renderer 应共享同一目录。休眠分支不能成为选中的 renderer。过期恢复不能覆盖新导航。snapshot 默认上限是有限的暂定值，增大前请实测；突然终止不保证最后一次保存。

`RouterHistory` 通过精确 plan 和普通策略提供有界的前进、后退及 checkpoint，保留 badge 和 presentation，不打开或关闭 scene。在账户/文档边界调用 `reset(sessionKey:)`；reset 或 stop 会使挂起的移动失效。

snapshot 持久化要求路由遵循 Codable，应用需自行定义 payload/schema 迁移。

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## 场景、系统集成与平台适配

声明无参数 `@Scene(.window)` / `@Scene(.immersiveSpace)` 路由，并在匹配的应用场景旁安装 `RouterSceneDriver`。使用窗口 UUID 及 `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle` 回调；visionOS 上用 `RouterImmersiveSpaceScene` 传递原生激活身份。每个 scene 在同一 store 中拥有独立子树，同时受平台 availability 限制。`RouterPlatformCapabilities.current` 描述支持范围，`RouterEvent.platformAdapted` 报告适配。`RouterUIKitBridge` / `RouterAppKitBridge` 共用同一管理者。`RouterOpenURLIntentBuilder`、`RouterShortcutCatalog`、`routerHandoff`、`continueRouterHandoff` 共用 URL 契约；Handoff 仅允许 HTTP(S)。

## 测试、Inspector 与可观测性

`RouterTestStore` 无需 host 即可运行真实 reducer 和策略。`RouterActionSequence` 保留转换上下文。`RouterInspectorRecorder` 提供有界、隐藏 payload 的时间线、diff、导入/导出和纯 reducer 回放，不修改 live store。默认导入上限为 8 MiB、5,000 条。`RouterObservability` 提供不含 payload 的日志/signpost，不发送 analytics。

`RouterScenarioRecorder` 记录执行控制，`RouterScenarioRunner` 重放取消和延后行为。fixture v9 支持仅导航的 v8；更旧或未知格式需重新采集。原始 fixture 含应用 payload，需要显式导出。`RouterScenarioSourceGenerator.generateFiles` 要求开发者提供期望结果。Inspector 支持英语及另外 15 种翻译，与七种 README 语言独立。

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## 迁移与历史文档

6.x → 7 是破坏性迁移：只读状态 draft、可抛错设置、固定 host 声明、有限资源预算、授权 generation、生命周期绑定结果。5.x 用户还需替换独立 store/intent 和已移除的细分产品。不要将归档 API 复制到当前应用。历史索引保留全部七种语言。

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## 验证与贡献

七种快速开始共享 API 示例与契约范围。静态检查不能证明 Swift 编译、DocC 渲染、原生 scene 行为或人工翻译审校。合并前请运行 Apple 工具链检查。`--no-parallel` 避免同步恢复测试替身耗尽协作线程池。不要在同一 scratch 目录同时运行多个 SwiftPM 构建。

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## 许可证与支持

MIT 许可证。欢迎贡献、问题报告和文档修正。

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
