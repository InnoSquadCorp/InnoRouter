# InnoRouter

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FInnoSquadCorp%2FInnoRouter%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FInnoSquadCorp%2FInnoRouter%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![codecov](https://codecov.io/gh/InnoSquadCorp/InnoRouter/branch/main/graph/badge.svg)](https://codecov.io/gh/InnoSquadCorp/InnoRouter)

InnoRouter 是一个 SwiftUI 原生的导航框架,围绕类型化状态、显式命令执行和应用边界深链接规划构建。

它将导航视为一等公民的状态机,而不是分散在视图局部的副作用。

## InnoRouter 拥有什么

InnoRouter 负责:

- 通过 `RouteStack` 管理栈式导航状态
- 通过 `NavigationCommand` 和 `NavigationEngine` 执行命令
- 通过 `NavigationStore` 提供 SwiftUI 导航权限
- 通过 `ModalStore` 提供 `sheet` 和 `fullScreenCover` 的模态权限
- 通过 `DeepLinkMatcher` 和 `DeepLinkPipeline` 进行深链接匹配和规划
- 通过 `InnoRouterEffects` 提供应用边界的执行助手

它有意不是通用的应用程序状态机。

请将以下关注点放在 InnoRouter 之外:

- 业务工作流状态
- 认证/会话生命周期
- 网络重试或传输状态
- 警告和确认对话框

## 要求

- iOS 18+
- iPadOS 18+
- macOS 15+
- tvOS 18+
- watchOS 11+
- visionOS 2+
- Swift 6.3+

iOS 18 floor 和 `swift-tools-version: 6.3` 包基线是有意为之:它们让每个公开类型
都能采用严格并发和 `Sendable`,而无需 `@preconcurrency` / `@unchecked Sendable`
逃生口,这意味着导航状态绝不会在视图代码和 store 之间的边界悄悄泄漏出 main actor。
代价是比那些目标 iOS 13–16 的库更小的采用窗口;好处是 router 的 `Sendable`/`@MainActor`
纪律由编译器检查而不是文字描述。

宏目标依赖 `swift-syntax` `603.0.2`,使用 `.upToNextMinor` 约束。InnoRouter 5.0
将包基线提升到 Swift 6.3,与该 host 依赖和 CI 固定的 Xcode 26.6 toolchain 对齐。
后续 Swift 基线提升仍只在主版本中进行。

| 并发态度 | InnoRouter | iOS 13+ 上的 TCA / FlowStacks / 其他 |
|---|---|---|
| 公开类型无条件声明 `Sendable` | ✅ | ⚠ 部分 — 许多使用 `@preconcurrency` |
| Store 是 `@MainActor` 隔离的,无运行时 hop | ✅ | ⚠ 视情况而定 |
| 源码中的 `@unchecked Sendable` / `nonisolated(unsafe)` | ❌ 无 | ⚠ 在某些适配器中使用 |
| 严格并发模式 | ✅ 按模块强制 | ⚠ 选择加入或部分启用 |

## 平台支持

InnoRouter 通过 SwiftUI 在每个 Apple 平台上发布。无需 UIKit 或 AppKit 桥接模块。

| 能力 | iOS | iPadOS | macOS | tvOS | watchOS | visionOS |
|---|---|---|---|---|---|---|
| `NavigationStore` / `NavigationHost` / `FlowStore` / `FlowHost` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `NavigationSplitHost` / `CoordinatorSplitHost` | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| `ModalHost` `.sheet` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `ModalHost` `.fullScreenCover` 原生 | ✅ | ✅ | ⚠ 降级 | ✅ | ⚠ 降级 | ⚠ 降级 |
| `TabCoordinator.badge` 状态 API / 原生视觉效果 | ✅ | ✅ | ✅ | ⚠ 仅状态 | ⚠ 仅状态 | ✅ |
| `DeepLinkPipeline` / `FlowDeepLinkPipeline` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `InnoRouterSpatial`：`SceneStore` / `innoRouterSceneHost` (windows、volumetric、immersive) | — | — | — | — | — | ✅ |
| `InnoRouterSpatial`：`innoRouterOrnament(_:content:)` 视图 modifier | no-op | no-op | no-op | no-op | no-op | ✅ |

`⚠ 降级` 表示 store API 不变地接受请求,但 SwiftUI host 因为 `.fullScreenCover`
不可用而将其渲染为 `.sheet`。`⚠ 仅状态` 表示 coordinator 存储并暴露 badge 状态,
但 `TabCoordinatorView` 因为 `.badge(_:)` 不可用而省略了 SwiftUI 的原生视觉
badge。`❌` 表示该符号在该平台上未声明;请用 `#if !os(...)` 包住构建。
空间路由表面是 5.0 的正式 opt-in API，不再标记为 experimental。

## 安装

```swift skip package-manifest-fragment
dependencies: [
    .package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "5.0.0")
]
```

请在应用目标中添加用于基础路由的 `InnoRouter` 产品。使用 visionOS scene 或 ornament
的目标还必须显式添加 `InnoRouterSpatial` 产品。`InnoRouter` 伞形目标不会重新导出
`InnoRouterSpatial`。
应用目标只需添加 `InnoRouter` 这一个产品。它同时提供运行时 API 和 macros，
因此源代码中只需一个 `import InnoRouter`。

InnoRouter 作为纯源码 SwiftPM 包发布。它不发布二进制工件,并且 library evolution
有意关闭,以便在 Apple 平台上保持源码构建的简单性。

文档门也保持至少一个完整的 Swift 片段对包进行类型检查:

```swift compile
import SwiftUI
import InnoRouter

@Router
enum CompileCheckedRoute {
    case detail

    var destination: some View {
        Text("Detail")
    }
}

@MainActor
func makeCompileCheckedHost() -> some View {
    RouterHost(CompileCheckedRoute.self) {
        Text("Home")
    }
}
```

## OSS 发布与 SemVer 合约

`4.0.0` 是 InnoRouter 的首个 OSS 发布,也是公开 SemVer 合约覆盖的第一个版本。
当前兼容性线从 `5.0.0` 开始。早期的私有/内部包快照不属于 OSS 兼容性线;
从 4.x 发布迁移的团队应遵循 [`CHANGELOG.md`](CHANGELOG.md) 中的 5.0 迁移说明。

### 5.x 线的 SemVer 承诺

在 `5.x.y` 发布中,InnoRouter 严格遵循 [Semantic Versioning](https://semver.org/):

- **`5.x.y` → `5.x.(y+1)`** 补丁发布:仅 bug 修复。无公开 API 签名变更。
  除修复文档化的 bug 外,无可观察行为变更。
- **`5.x.y` → `5.(x+1).0`** 次版本发布:仅添加。新类型、新方法、新 case、
  新配置选项。现有签名保持其形状,现有调用点未经修改即可编译。
- **`5.x.y` → `6.0.0`** 主版本发布:任何破坏源代码兼容性、删除公开符号、
  收窄泛型约束,或以可能令现有调用点惊讶的方式更改文档化运行时行为的事项。

预发布标签使用 `5.0.0-rc.1` / `5.1.0-beta.2` 形式。统一的 strict 版本策略
只接受无前导零的 GA、`rc` 和 `beta` 标识符。预发布标签 push 会完成验证但不发布;
实际发布需按 [`RELEASING.md`](RELEASING.md) 手动运行 `release.yml`,并设置
`prerelease=true`。

### 什么算破坏性变更

就 5.x SemVer 承诺而言,*破坏性变更*指以下任何之一:

- 删除或重命名公开符号(类型、方法、属性、associated type、case)。
- 以使现有调用点编译失败的方式更改公开方法签名(添加非默认参数、收紧泛型
  约束、交换返回类型)。
- 更改公开 API 的文档化行为,使现有的正确调用者产生不同的可观察结果(例如,
  翻转默认 `NavigationPathMismatchPolicy`)。
- 提高最低支持的 Swift toolchain 或平台基线。

相反,以下*不是*破坏性的,可能在任何次版本发布中登陆:

- 向非 `@frozen` 公开 enum 添加新 case。
- 向公开方法添加新的默认参数。
- 收紧仅内部的类型。
- 保留语义的性能改进。
- 仅文档变更。

### 4.x 历史记录

`4.1.0` 是预用户清理 pass 之后的采用基线。它移除了未使用的 dispatcher 对象 API,
将 `replaceStack` 保留为唯一的全栈替换 intent,并将 effect 观察转移到显式事件流。
这是 4.x 线中唯一文档化的源码破坏性例外。`4.0.0` 标签仍保留为首个 OSS 快照;
完整的 4.x 历史和 5.0 迁移记录在 [`CHANGELOG.md`](CHANGELOG.md) 中。

### Imports

伞形目标 `InnoRouter` 重新导出 `InnoRouterCore`、`InnoRouterSwiftUI`、
`InnoRouterDeepLink` 和 macro 声明。因此 `@Router`、`@Routable` 和
`@CasePathable` 都可以通过一个 import 使用。空间路由和 app-boundary effects
仍是独立产品；`InnoRouter` 不会重新导出 `InnoRouterSpatial`:

```swift skip doc-fragment
import InnoRouter            // stores、stack/modal hosts、intents、deep links
import InnoRouterSpatial     // 仅在使用 visionOS scenes 和 ornaments 时
import InnoRouterEffects     // app-boundary 执行与 pending replay
```

`@Router`、`RouterHost`、`@EnvironmentRouter` 以及高级属性包装器和
视图修饰符都来自 `InnoRouter`。

SwiftSyntax 支持的 macro 实现包含在此包中。package-traits 或独立 macro 包拆分
应在测量 `swift package show-traits`、
`swift build --target InnoRouter` 和 `swift build --target InnoRouterMacros`
对照迁移成本之后才评估。

| 产品 | 何时导入 |
|---|---|
| `InnoRouter` | 应用代码的默认产品：macros、router hosts、stack/modal stores、intents、coordinators、deep links 和持久化助手。 |
| `InnoRouterSpatial` | 使用 visionOS scenes、immersive spaces 或 ornaments 路由的应用目标。请与 `InnoRouter` 分开添加并导入该产品。 |
| `InnoRouterMacros` | 需要 macros 与 Core/SwiftUI API、但不需要完整 deep-link 伞形表面的目标所用的细分产品；应用目标通常使用 `InnoRouter`。 |
| `InnoRouterEffects` | 执行 `NavigationCommand` 值并处理或恢复挂起深链接的应用边界代码。 |
| `InnoRouterTesting` | 想要无 host 的 `NavigationTestStore`、`ModalTestStore` 或 `FlowTestStore` 的测试目标。 |

## 模块

- `InnoRouter`:`InnoRouterCore`、`InnoRouterSwiftUI`、`InnoRouterDeepLink` 和 macro 声明的伞形重新导出
- `InnoRouterCore`:route stack、validators、commands、results、batch/transaction executors、middleware
- `InnoRouterSwiftUI`:stores、stack/split/modal/flow hosts、coordinators 和类型化 `EnvironmentRouter` actions
- `InnoRouterSpatial`:opt-in visionOS scene/immersive-space stores、hosts、anchors 和 ornaments
- `InnoRouterDeepLink`:模式匹配、诊断、pipeline 规划、挂起深链接
- `InnoRouterEffects`:用于应用边界的导航与深链接执行助手
- `InnoRouterMacros`:提供 `@Router`、`@Routable` 和 `@CasePathable` 的细分 macro 产品

## 选择正确的表面

使用拥有所需转换权限的最小表面:

| 需求 | 使用 |
|---|---|
| 一个自包含的类型化 SwiftUI 栈 | `@Router` + `RouterHost` |
| 由深链接、恢复、middleware 或应用状态拥有的栈 | `NavigationStore` + `NavigationHost` |
| 在支持的平台上的分屏视图栈 | `NavigationStore` + `NavigationSplitHost` |
| 不重置栈的 sheet / cover 权限 | `ModalStore` + `ModalHost` |
| Push + modal 流程、恢复或多步深链接 | `FlowStore` + `FlowHost` + `FlowPlan` |
| URL 转 push-only 命令计划 | `DeepLinkMatcher` + `DeepLinkPipeline` |
| URL 转 push-prefix 加 modal-tail 流程 | `DeepLinkMatcher<FlowPlan<R>>` + `FlowDeepLinkPipeline` |
| visionOS windows、volumes、immersive spaces | `InnoRouterSpatial` + `SceneStore` + `innoRouterSceneHost` / `innoRouterSceneAnchor` |
| Reducer、effect 或应用边界执行 | `InnoRouterEffects` |
| 无 SwiftUI hosts 的 router 断言 | `InnoRouterTesting` |

`NavigationStore`、`FlowStore`、`ModalStore`、`SceneStore`、effects 和 testing
有意分离。选择 visionOS 空间表面时，请在应用目标中添加 `InnoRouterSpatial` 产品，
并在相关源码文件中使用 `import InnoRouterSpatial`。该库保持这些权限明确,以便应用只采用
与其路由边界匹配的部分。

### 快速决策流程图

```text
屏幕表面是否在一个流程中结合了 push 和 modal?
├── 是 → FlowStore + FlowHost (单一真相源、单一事件流)
└── 否 → 它是否仅拥有模态权限(sheet / cover)?
         ├── 是 → ModalStore + ModalHost
         └── 否 → @Router + RouterHost
                 (外部 authority: NavigationStore + NavigationHost;
                  分屏视图: NavigationSplitHost)
```

从视图进行普通 stack 导航时，请使用 `@EnvironmentRouter` 的 `go` / `back`。
只有在需要显式 navigation、modal 或 flow 语义时，才使用
[`Docs/IntentSelectionGuide.md`](Docs/IntentSelectionGuide.md) 中的底层 intent。

## 文档

- 最新 DocC 门户: [InnoRouter latest docs](https://innosquadcorp.github.io/InnoRouter/latest/)
- 版本化 docs 根目录: [InnoRouter docs](https://innosquadcorp.github.io/InnoRouter/)
- 发布检查清单: [RELEASING.md](RELEASING.md)
- 维护者快速指南: [CLAUDE.md](CLAUDE.md)

`README.md` 是仓库的入口点。
DocC 是详细的模块级参考集合。

### 教程文章

针对最常见采用路径的逐步演练。每篇文章都位于相关 DocC 目录中,因此渲染的 DocC 站点、
GitHub 源代码视图和离线 `swift package generate-documentation` 构建都显示相同内容。

| 文章 | 目录 | 涵盖 |
| --- | --- | --- |
| [Tutorial-LoginOnboarding](Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Tutorial-LoginOnboarding.md) | `InnoRouterSwiftUI` | 使用 `FlowStore` 和 `ChildCoordinator` 构建登录 → onboarding → 主页流程 |
| [Tutorial-DeepLinkReconciliation](Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Tutorial-DeepLinkReconciliation.md) | `InnoRouterSwiftUI` | 协调 cold-start vs warm 深链接,包括挂起重放 |
| [Tutorial-MiddlewareComposition](Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Tutorial-MiddlewareComposition.md) | `InnoRouterSwiftUI` | 组合类型化 middleware、拦截命令、观察 churn |
| [Tutorial-MigratingFromNestedHosts](Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Tutorial-MigratingFromNestedHosts.md) | `InnoRouterSwiftUI` | 用 `FlowHost` 替换嵌套的 `NavigationHost` + `ModalHost` 栈 |
| [Tutorial-Throttling](Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Tutorial-Throttling.md) | `InnoRouterSwiftUI` | 配合确定性测试 clock 使用 `ThrottleNavigationMiddleware` |
| [Tutorial-VisionOSScenes](Sources/InnoRouterSpatial/InnoRouterSpatial.docc/Articles/Tutorial-VisionOSScenes.md) | `InnoRouterSpatial` | 从 `SceneStore` 驱动 visionOS windows、volumetric scenes 和 immersive spaces |
| [Tutorial-FlowDeepLinkPipeline](Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/Tutorial-FlowDeepLinkPipeline.md) | `InnoRouterDeepLink` | 通过 `FlowDeepLinkPipeline` 构建组合 push + modal 深链接 |
| [Tutorial-StatePersistence](Sources/InnoRouterCore/InnoRouterCore.docc/Tutorial-StatePersistence.md) | `InnoRouterCore` | 使用 `StatePersistence` 跨启动持久化 `FlowPlan` / `RouteStack` |
| [Tutorial-TestingFlows](Sources/InnoRouterTesting/InnoRouterTesting.docc/Articles/Tutorial-TestingFlows.md) | `InnoRouterTesting` | 通过 `FlowTestStore` 进行无 host 的 Swift Testing 断言 |

## 工作原理

### 运行时流程

```mermaid
flowchart LR
    View["SwiftUI 视图"] --> Actions["@EnvironmentRouter 类型化 actions"]
    Actions --> Store["NavigationStore / ModalStore / FlowStore"]
    Store --> Policy["Middleware / 观察 / 验证"]
    Policy --> Execution["NavigationEngine / 模态队列"]
    Execution --> Host["RouterHost / NavigationHost / ModalHost / FlowHost"]
    Host --> System["NavigationStack / NavigationSplitView / sheet / fullScreenCover"]
```

- 视图通过 `@EnvironmentRouter` 调用按 route 类型化的 action。
- Store 拥有导航、模态或统一 flow 权限。
- Host 将 store 状态翻译为原生 SwiftUI 导航 API。

### 深链接流程

```mermaid
flowchart LR
    URL["传入 URL"] --> Match["DeepLinkMatcher"]
    Match --> Plan["DeepLinkPipeline"]
    Plan --> Effect["DeepLinkEffectHandler"]
    Effect --> Decision{"现在已授权?"}
    Decision -->|"否"| Pending["PendingDeepLink"]
    Decision -->|"是"| Execute["Batch / transaction 执行"]
    Execute --> Store["NavigationStore / ModalStore"]
```

- 匹配和规划保持纯净。
- Effect 处理器是应用策略决定是现在执行还是延迟的边界。
- 挂起深链接保留计划的转换,直到应用准备好重放它。

## 快速开始

添加 `InnoRouter` 产品并只导入 `InnoRouter`。`@Router` 会生成必要的 route
conformance，并在编译时验证 `destination` 声明。

### 1. 定义 Router 和目的地

```swift skip doc-fragment
import SwiftUI
import InnoRouter

@Router
enum HomeRoute {
    case detail(id: String)
    case settings

    var destination: some View {
        switch self {
        case .detail(let id):
            Text("Detail \(id)")
        case .settings:
            Text("Settings")
        }
    }
}
```

### 2. 使用 `RouterHost` 托管

```swift skip doc-fragment
struct AppRoot: View {
    var body: some View {
        RouterHost(HomeRoute.self) {
            HomeListView()
        }
    }
}
```

`RouterHost` 会拥有本地 `FlowStore`；在这条简单路径中，无需手动创建 store。

### 3. 从子视图导航

```swift skip doc-fragment
struct HomeListView: View {
    @EnvironmentRouter(HomeRoute.self) private var router

    var body: some View {
        List {
            Button("Detail") {
                router.go(.detail(id: "123"))
            }

            Button("Settings") {
                router.go(.settings)
            }

            Button("Back") {
                router.back()
            }
        }
    }
}
```

`@EnvironmentRouter` 会提供类型安全的操作，而不向视图暴露 store。需要状态恢复、
middleware 或 deep-link 协调的高级应用仍可直接使用 `NavigationStore` 和
`NavigationHost`。

## 状态和执行模型

InnoRouter 暴露三种不同的执行语义。

### 单一命令

`execute(_:)` 应用一个 `NavigationCommand` 并返回类型化的 `NavigationResult`。

### Batch

`executeBatch(_:stopOnFailure:)` 保留每步的命令执行,但合并观察。

何时使用 batch 执行:

- 多个命令仍应一个接一个地运行
- middleware 仍应看到每一步
- 观察者仍应收到一个聚合的转换事件

### Transaction

`executeTransaction(_:)` 在影子栈上预览命令,仅当每一步都成功时才提交。

何时使用 transaction 执行:

- 不接受部分成功
- 你希望在失败或取消时回滚
- 全有或全无的提交事件比逐步观察更重要

### `.sequence`

`.sequence` 是命令代数,不是事务。

它有意是:

- 从左到右
- 非原子
- 通过 `NavigationResult.multiple` 类型化

即使后面的步骤失败,先前成功的步骤仍保持应用。

### `send(_:)` vs `execute(_:)` — 选择正确的入口点

InnoRouter 按目的对视图操作和 store/engine API 进行分层。
请选择匹配调用点的入口,而不是匹配数据形状的入口。

| 层 | 入口 | 何时使用 |
| --- | --- | --- |
| 视图操作(默认) | `router.go(_:)`、`router.back()`、… | 从普通 SwiftUI 视图通过 `@EnvironmentRouter` 路由。 |
| 视图 intent(高级) | `router.send(_:)` | 发送没有命名便捷方法的 `NavigationIntent`。 |
| 外部 store 边界 | `store.send(_:)` | 应用有意在外部持有并注入 `NavigationStore`。 |
| Command | `store.execute(_:)` | 将单个 `NavigationCommand` 转发到 engine 并检查类型化 `NavigationResult`。 |
| Batch | `store.executeBatch(_:)` | 一个接一个运行多个命令,同时保持 middleware 可见性和单个观察者事件。 |
| Transaction | `store.executeTransaction(_:)` | 全有或全无地提交 — 对照影子栈预览,然后仅当每一步都成功时才提交。 |

经验法则:

- 普通视图使用 `@EnvironmentRouter`;只有明确的外部 store 边界才调用
  `store.send`。Coordinators 和 effect 边界执行命令。
- `send` 是 intent 形态(无返回值可检查);`execute*` 是命令形态(返回类型化结果用于分支、遥测、重试)。
- 对于必须在部分失败时回滚的原子多步流程,优先使用 `executeTransaction` 而不是手工 batch。

相同的分层适用于 `ModalStore` 和 `FlowStore`:
来自视图的 `send(_: ModalIntent)` / `send(_: FlowIntent)`,以及在 engine 边界
的 `execute(_:)` / `executeBatch(_:)` / `executeTransaction(_:)`。

### 在 `.sequence`、`executeBatch` 和 `executeTransaction` 之间选择

| 你想要… | 使用 | 原因 |
|---|---|---|
| 多个命令的一个可观察变更,尽力而为 | `executeBatch(_:stopOnFailure:)` | 通过 `onEvent` / `events` 合并的 `.changed` 与 `.batchExecuted`、可选 fail-fast |
| 全有或全无的应用并支持回滚 | `executeTransaction(_:)` | 影子状态预览、基于 journal 的丢弃 |
| engine 规划/验证的组合*值* | `NavigationCommand.sequence([...])` | 纯命令,作为一个单元流过每个 middleware |
| 在静默窗口后仅触发最新命令 | `DebouncingNavigator` | Async 包装 navigator、`Clock` 可注入 |
| 按 key 速率限制 | `ThrottleNavigationMiddleware` | 同步、最后接受时间戳 |

带有工作示例和反模式的完整决策矩阵存在于 DocC 教程
[`Guide-SequenceVsBatchVsTransaction`](Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Guide-SequenceVsBatchVsTransaction.md)。

## 栈路由表面

`NavigationIntent` 是完整的 SwiftUI 栈 intent 表面:

- `.go(Route)`
- `.goMany([Route])`
- `.back`
- `.backBy(Int)`
- `.backTo(Route)`
- `.backToRoot`
- `.replaceStack([Route])`

Macro-first 视图通常无需了解 store。通过 `@EnvironmentRouter` 获取操作,
常见转换使用 `router.go(_:)` / `router.back()`,高级 intent 使用
`router.send(_:)`。仅在应用有意从外部持有并注入 store 的边界调用
`NavigationStore.send(_:)`。

## 模态路由表面

InnoRouter 支持以下模态路由:

- `sheet`
- `fullScreenCover`

使用:

- `ModalStore`
- `ModalHost`
- `ModalIntent`
- `@EnvironmentRouter`

示例:

```swift skip doc-fragment
@Routable
enum AppModalRoute {
    case profile
    case onboarding
}

struct ShellView: View {
    @State private var modalStore = ModalStore<AppModalRoute>()

    var body: some View {
        ModalHost(store: modalStore) { route in
            switch route {
            case .profile:
                ProfileView()
            case .onboarding:
                OnboardingView()
            }
        } content: {
            HomeView()
        }
    }
}
```

### 模态作用域边界

在 iOS 和 tvOS 上,`ModalHost` 直接将样式映射到 `sheet` 和 `fullScreenCover`。
在其他支持的平台上,`fullScreenCover` 安全地降级为 `sheet`。

InnoRouter **有意不**拥有:

- `alert`
- `confirmationDialog`

将这些保留为 feature-local 或 coordinator-local 的呈现状态。

### 模态可观察性

`ModalStoreConfiguration` 提供一个类型化观察回调和异步流:

- `logger`
- `onEvent: (ModalEvent<M>) -> Void`
- `ModalStore.events: AsyncStream<ModalEvent<M>>`

对 `ModalEvent` 使用 `switch` 来处理呈现、关闭、替换、队列变化、命令拦截
和 middleware 变更。

`ModalDismissalReason` 区分:

- `.dismiss`
- `.dismissAll`
- `.systemDismiss`

### 模态 middleware

`ModalStore` 暴露与 `NavigationStore` 相同的 middleware 表面:

- 带 `willExecute` / `didExecute` 的 `ModalMiddleware` / `AnyModalMiddleware<M>`。
- `ModalInterception` 让 middleware `.proceed(command)`(包括重写的命令)
  或带 `ModalCancellationReason` 的 `.cancel(reason:)`。
- `ModalStore.addMiddleware` / `insertMiddleware` / `removeMiddleware` /
  `replaceMiddleware` / `moveMiddleware` — 与导航匹配的基于 handle 的 CRUD。
- `execute(_:) -> ModalExecutionResult<M>` 通过 registry 路由所有
  `.present`、`.dismissCurrent` 和 `.dismissAll`。
- `ModalMiddlewareMutationEvent` 为分析浮现 registry churn。

## 分屏导航

对于 iPad 和 macOS 详情导航,使用:

- `NavigationSplitHost`
- `CoordinatorSplitHost`

InnoRouter 在分屏布局中仅拥有详情栈。

以下保持应用所有:

- 侧边栏选择
- 列可见性
- 紧凑适配

## Coordinator 表面

Coordinator 是位于 SwiftUI intent 和命令执行之间的策略对象。

何时使用 `CoordinatorHost` 或 `CoordinatorSplitHost`:

- 视图 intent 需要先经过策略路由
- 应用 shell 需要协调逻辑
- 多个导航权限应在一个 coordinator 后组合

`StepCoordinator` 和 `TabCoordinator` 是助手,而不是 `NavigationStore` 的替代品。

推荐分工:

- `NavigationStore`:route-stack 权限
- `TabCoordinator`:shell/tab 选择状态
- `StepCoordinator`:目的地内的局部步骤进展

### 子 coordinator 链接

`ChildCoordinator` 让父 coordinator 通过
`parent.push(child:) -> Task<Child.Result?, Never>` inline await 完成值:

```swift skip doc-fragment
let signupResult = await parentCoordinator.push(child: SignUpCoordinator())
if let user = signupResult {
    parentCoordinator.handle(.go(.home(user)))
}
```

回调(`onFinish`、`onCancel`)同步安装,因此子可以在任何时候触发它们,
包括在父的 `await` 之前。设计原理见
[`Docs/design-child-coordinator-handoff.md`](Docs/design-child-coordinator-handoff.md)。

父 `Task` 取消通过 `ChildCoordinator.parentDidCancel()`(默认空 no-op)
传播到子。覆盖它以拆除瞬态状态 — 关闭 sheet、取消进行中的请求、释放临时 store
— 当父视图被消除时:

```swift skip doc-fragment
final class SignUpCoordinator: ChildCoordinator {
    typealias Result = UserID
    var onFinish: (@MainActor @Sendable (UserID) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?

    func parentDidCancel() {
        signUpAPIClient.cancelActiveRequests()
    }
}
```

`parentDidCancel` 是有方向的(父 → 子)。它不调用 `onCancel`(后者保持子 → 父);
两个 hook 是正交的。

## 命名导航 intent

高频 intent 由现有 `NavigationCommand` 原语组合而成:

- `NavigationIntent.replaceStack([R])` — 在一个可观察步骤中将栈重置为给定的路由。
- `NavigationIntent.backOrPush(R)` — 如果 `route` 已在栈中,则 pop 到它,否则 push。
- `NavigationIntent.pushUniqueRoot(R)` — 仅当栈不包含相等路由时 push。

这些通过正常的 `send` → `execute` pipeline 路由,因此 middleware 和遥测的观察
与直接 `NavigationCommand` 调用相同。

## Case 类型化目的地绑定

`NavigationStore` 和 `ModalStore` 暴露由 `@Routable` / `@CasePathable`
发出的 `CasePath` 索引的 `binding(case:)` 助手:

```swift skip doc-fragment
struct DetailSheet: View {
    let store: NavigationStore<AppRoute>

    var body: some View {
        SomeDetailView()
            .sheet(item: store.binding(case: AppRoute.Cases.detail)) { detail in
                DetailView(detail: detail)
            }
    }
}
```

绑定通过现有命令 pipeline 路由每个 set,因此 middleware 和遥测的观察
与直接 `execute(...)` 调用完全相同。`ModalStore.binding(case:style:)` 按
呈现样式作用域(`.sheet` / `.fullScreenCover`)。

## 深链接模型

深链接被作为计划处理,而不是隐藏的副作用。

核心部分:

- `DeepLinkMatcher`
- `DeepLinkPipeline`
- `DeepLinkDecision`
- `PendingDeepLink`
- `NavigationPlan`

典型流程:

1. 将 URL 匹配到路由
2. 按 scheme/host 拒绝或接受
3. 应用认证策略
4. 发出 `.plan`、`.pending`、`.rejected` 或 `.unhandled`
5. 显式执行结果导航计划

### Matcher 诊断

`DeepLinkMatcher` 为 route 和 `FlowPlan` 输出提供相同的诊断:

- 重复模式
- 通配符 shadowing
- 参数 shadowing
- 非终结通配符

诊断不更改声明顺序优先级。它们帮助捕获创作错误,而不会悄悄地改变运行时行为。
当诊断应使构建失败时,请在发布就绪门中使用 `try DeepLinkMatcher(strict:)`。

### 组合深链接(push + modal tail)

`FlowDeepLinkPipeline` 扩展了仅 push pipeline,使单个 URL 可以在一个原子
`FlowStore.apply(_:)` 中重新水合 push 前缀**加上**模态终端步骤:

```swift skip doc-fragment
let matcher = DeepLinkMatcher<FlowPlan<AppRoute>> {
    DeepLinkMapping("/home/detail/:id") { params in
        guard let id = params.firstValue(forName: "id") else { return nil }
        return FlowPlan(steps: [.push(.home), .push(.detail(id: id))])
    }
    DeepLinkMapping("/onboarding/privacy") { _ in
        FlowPlan(steps: [.sheet(.privacyPolicy)])
    }
}

let pipeline = FlowDeepLinkPipeline(
    allowedSchemes: ["myapp"],
    allowedHosts: ["app"],
    matcher: matcher,
    authenticationPolicy: .required(
        shouldRequireAuthentication: { _ in true },
        isAuthenticated: { SessionStore.shared.isAuthenticated }
    )
)

let handler = FlowDeepLinkEffectHandler(pipeline: pipeline, applier: flowStore)

FlowHost(store: flowStore, destination: destination) { RootView() }
    .onOpenURL { _ = handler.handle($0) }
```

每个 `DeepLinkMapping<FlowPlan<R>>` 处理器返回**完整**的 `FlowPlan`,因此多段 URL 在
声明站点是显式的。pipeline 逐字重用仅 push pipeline 的
`DeepLinkAuthenticationPolicy` + `PendingDeepLink` 语义,以实现对称的认证延迟
和重放。完整演练参见
[`Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/Tutorial-FlowDeepLinkPipeline.md`](Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/Tutorial-FlowDeepLinkPipeline.md)。

## Middleware

Middleware 在命令执行周围提供横切策略层。

预执行:

- `willExecute(_:state:) -> NavigationInterception`
- `.proceed(updatedCommand)`
- `.cancel(reason)`

后执行:

- `didExecute(_:result:state:) -> NavigationResult`

Middleware 可以:

- 重写命令
- 用类型化取消原因阻止执行
- 在执行后折叠结果

Middleware 不能直接变更 store 状态。

### 类型化取消

取消原因使用 `NavigationCancellationReason`:

- `.middleware(debugName:command:)`
- `.conditionFailed`
- `.custom(String)`

### Middleware 管理

`NavigationStore` 暴露基于 handle 的管理:

- `addMiddleware`
- `insertMiddleware`
- `removeMiddleware`
- `replaceMiddleware`
- `moveMiddleware`
- `middlewareMetadata`

## 路径协调

SwiftUI `NavigationStack(path:)` 更新被映射回语义命令。

规则:

- 前缀缩短 → `.popCount` 或 `.popToRoot`
- 前缀扩展 → 批量 `.push`
- 非前缀不匹配 → `NavigationPathMismatchPolicy`

可用的不匹配策略:

- `.replace` — 默认生产姿态;接受 SwiftUI 的非前缀路径重写并发出不匹配事件。
- `.assertAndReplace` — 调试 / 预发布姿态;assert 然后用相同的替换语义恢复。
- `.ignore` — store 权威姿态;观察重写但保持当前栈不变。
- `.custom` — 域修复姿态;将旧/新路径映射到一个命令、一个 batch 或 no-op。

当 `NavigationStoreConfiguration.logger` 设置时,不匹配处理会发出结构化遥测。

## Effect 模块

### `InnoRouterEffects`

当应用 shell 代码想要 navigator 边界上的小型执行 façade 时使用。

关键 API:

- `execute(_:)`
- `execute(_ commands:)`
- `executeTransaction(_:)`
- `executeGuarded(_:, prepare:)`

除了显式 async guard 助手外,这些 API 都是同步 `@MainActor` API。

当应在带类型化结果的应用边界执行深链接计划时使用。

关键 API:

- `handle(_ url:)`
- `resumePendingDeepLink()`
- `resumePendingDeepLinkIfAllowed(_:)`
- `restore(pending:)`

### Coordinator 集成

基于 coordinator 的 app 在 store 旁持有一个 `DeepLinkEffectHandler`,并通过
`init(pipeline:navigator:)` 注入已配置的 pipeline。URL 委托给 `handle(_:)`,
replay 使用 `resumePendingDeepLink()` 或 `resumePendingDeepLinkIfAllowed(_:)`,
结果按 `DeepLinkEffectHandler.Result` 处理。Pending request identity 由 handler
持有;应用在内存中交接的值通过 `restore(pending:)` 重新安装。若 UI 需要观察,
coordinator 可将返回结果同步到自身状态。跨启动持久化请使用
`FlowPendingDeepLinkPersistence`。

## `Examples` vs `ExamplesSmoke`

仓库有意将文档示例与 CI 示例分开。

- `Examples/`:面向人的、惯用的、基于 macro 的示例
- `ExamplesSmoke/`:用于 CI 的编译器稳定 smoke 固件

当前示例涵盖:

- 独立栈路由
- coordinator 路由
- 深链接
- 分屏导航
- 应用 shell 组合
- 模态路由

## 文档和发布流程

### DocC

DocC 按模块构建并发布到 GitHub Pages。

发布结构:

- `/InnoRouter/latest/`
- `/InnoRouter/4.3.0/`
- `/InnoRouter/` 根门户

### CI

CI 验证:

- `swift test`
- `principle-gates`
- `platforms` 工作流：编译所有 Apple 平台目标，并运行 tvOS/watchOS/visionOS 运行时测试
- 示例 smoke 构建
- DocC 预览构建

### CD

GA 发布仅在 strict 裸 semver 标签上运行:

- `5.0.0`

无效标签示例:

- 任何带前导 `v` 的标签
- `release-5.0.0`

发布工作流职责:

- 验证 exact tag、`main` ancestry 以及标签中的 `CHANGELOG.md`
- 重新运行代码/文档门
- 调用可复用的 `platforms` 门禁，并在其通过前阻止发布；本地 `./scripts/principle-gates.sh --platforms=all` 仅执行编译检查，不能替代这些运行时测试
- 构建版本化 DocC
- 仅当 GA 不低于已发布的最高 GA 时更新 `/latest/`
- 保留旧版本化文档
- 发布 GitHub Release

### SwiftUI 哲学对齐

InnoRouter 遵循 SwiftUI 的声明式方向,同时为共享导航权限做出有意的权衡。

- 视图发出 intent,而不是直接变更 router 状态。
- 栈、分屏详情和模态权限保持分离。
- 缺失的 environment 接线快速失败。
- `NavigationStore` 保持引用类型,因为它是共享权限,而不是临时局部状态。
- `Coordinator` 出于相同原因保持 `AnyObject`。

这是有意的实用权衡,而不是与 SwiftUI 的意外漂移。

## Examples

面向人的示例位于此处:

- [Examples/StandaloneExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/StandaloneExample.swift)
- [Examples/CoordinatorExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/CoordinatorExample.swift)
- [Examples/DeepLinkExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/DeepLinkExample.swift)
- [Examples/SplitCoordinatorExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/SplitCoordinatorExample.swift)
- [Examples/AppShellExample.swift](https://github.com/InnoSquadCorp/InnoRouter/blob/main/Examples/AppShellExample.swift)

## 质量门

在切发布之前在本地运行这些:

```bash
swift test
./scripts/principle-gates.sh
./scripts/build-docc-site.sh --version preview --skip-latest
```

## Flow 栈

`FlowStore<R>` 将统一的 push + sheet + cover 流表示为单个
`RouteStep<R>` 值数组。它拥有内部 `NavigationStore<R>` 和 `ModalStore<R>`,
委托给每个,同时强制不变量(尾部最多一个 modal、modal 始终在尾部、
middleware 回滚协调路径)。

那些内部 store 是实现细节。应用代码应将 `FlowStore.path`、`send(_:)`、
`apply(_:)` 和 `events` 视为公开权限表面;直接的内部 store 变更保留给
host 和聚焦的不变量测试。

典型用法:

```swift skip doc-fragment
let flow = FlowStore<AppRoute>()
let restoredFlow = try FlowStore<AppRoute>(
    validating: persistedSteps
)

flow.send(.push(.home))
flow.send(.push(.detail(id)))
flow.send(.presentSheet(.share))   // tail modal
flow.apply(FlowPlan(steps: [.push(.home), .cover(.paywall)]))
```

- `FlowHost` 基于 `FlowStore` 渲染不发布 environment authority 的导航和模态
  surface，然后为 `@EnvironmentRouter(Route.self)` 发布一个统一 authority。
  Flow 专用 intent 通过 `router.send(flow:)` 发送。
- `FlowStoreConfiguration` 组合 `NavigationStoreConfiguration` 和
  `ModalStoreConfiguration`,并为 `FlowEvent` 添加单个 `onEvent` 回调。
  它接收 flow 级 path/rejection 以及包装为 `.navigation(...)` /
  `.modal(...)` 的内部事件。
- `FlowStore(validating:configuration:)` 是用于恢复的或外部提供的
  `[RouteStep]` 值的 throwing initializer;兼容性 `initial:` initializer
  仍将无效输入强制为空路径。
- `FlowRejectionReason` 浮现运行时拒绝原因
  (`pushBlockedByModalTail`、`invalidResetPath`、`middlewareRejected(debugName:)`、
  `reentrantApply`)。

## 无 Host 测试 (`InnoRouterTesting`)

`InnoRouterTesting` 是包装 `NavigationStore`、`ModalStore` 和 `FlowStore`
的可发布 Swift Testing 原生断言 harness。测试不再需要
`@testable import InnoRouterSwiftUI` 或手工的 `Mutex<[Event]>` 收集器 —
每个公开观察事件都被缓冲到 FIFO 队列中,测试用 TCA 风格的 `receive(...)`
调用排空它。

仅向测试目标添加产品:

```swift skip doc-fragment
// Package.swift
.testTarget(
    name: "AppTests",
    dependencies: [
        .product(name: "InnoRouter", package: "InnoRouter"),
        .product(name: "InnoRouterTesting", package: "InnoRouter"),
    ]
)
```

然后针对生产 intent 编写测试:

```swift skip doc-fragment
import Testing
import InnoRouter
import InnoRouterTesting

@Test
@MainActor
func pushHomeThenDetail() {
    let store = NavigationTestStore<AppRoute>()

    store.send(.go(.home))
    store.receiveChange { _, new in new.path == [.home] }

    store.executeBatch([.push(.detail("42"))])
    store.receiveChange { _, new in new.path == [.home, .detail("42")] }
    store.receiveBatch { $0.isSuccess }

    store.finish()
}
```

Harness 涵盖:

- **`NavigationTestStore<R>`** — 所有 `NavigationEvent` case:
  `.changed`、`.batchExecuted`、`.transactionExecuted`、`.middlewareMutation`
  和 `.pathMismatch`。
  将 `send`、`execute`、`executeBatch`、`executeTransaction` 不变地
  转发到底层 store。
- **`ModalTestStore<M>`** — 所有 `ModalEvent` case,包括 `.presented`、
  `.dismissed`、`.replaced`、`.queueChanged`、`.commandIntercepted`
  和 `.middlewareMutation`。
- **`FlowTestStore<R>`** — FlowStore 级别的 `.pathChanged` + `.intentRejected`,
  加上围绕单个队列上内部 store 发射的 `.navigation(...)` 和 `.modal(...)` 包装器。
  一个测试可以断言由单个 `FlowIntent` 触发的完整链,包括 middleware 取消路径。

完备性默认为 `.strict`:store deinit 时任何未断言的事件都触发 Swift Testing issue。
对于从遗留测试固件的增量迁移使用 `.off`。

## 状态恢复

选择加入 `Codable` 的路由免费获得可往返的 `RouteStack`、`RouteStep` 和
`FlowPlan` 值:

```swift skip doc-fragment
enum AppRoute: Route, Codable {
    case home
    case detail(String)
    case settings
}

let persistence = StatePersistence<AppRoute>()

// 在 scene 后台 / 检查点:
let data = try persistence.encode(FlowPlan(steps: flowStore.path))
try data.write(to: restorationURL, options: .atomic)

// 启动时:
if let data = try? Data(contentsOf: restorationURL) {
    flowStore.apply(try persistence.decode(data))
}
```

`StatePersistence<R: Route & Codable>` 包装一个 `JSONEncoder` 和
`JSONDecoder`(都可配置)并在 `Data` 边界停止 — 文件 URL、`UserDefaults`、
iCloud 和 scene-phase hook 是应用关注点。错误作为底层 `EncodingError` /
`DecodingError` 传播,因此调用者可以区分 schema 漂移和 I/O 失败。

`FlowPlan(steps: flowStore.path)` 是当前可见流的快照:它存储导航 push 栈
加上活动模态尾部(如果可见)。它不序列化模态 backlog。排队的呈现作为内部
执行状态存在于 `ModalStore.queuedPresentations` 中,在当前 `FlowPlan`
持久化合约之外。必须恢复排队模态工作的应用应在 `FlowPlan` 旁边持久化
应用拥有的队列快照,并在启动后通过自己的路由策略重放它。

## 统一观察流

每个 store 都发布单个 `events: AsyncStream`,涵盖完整的观察表面 — 栈变更、
batch / transaction 完成、路径不匹配解决、middleware-registry 变更、
模态 present / dismiss / queue 更新、命令拦截,以及 flow 级路径或 intent
拒绝信号。

在启动由生命周期管理的 Task 之前先获取一个新的 stream。这样 subscriber 会
同步注册，不会漏掉 Task 创建后立即发出的事件；所有者结束时取消
`observationTask`。

```swift skip doc-fragment
let events = flowStore.events
let observationTask = Task { @MainActor in
    for await event in events {
        switch event {
        case .navigation(.changed(_, let to)):
            analytics.track("nav_path", to.path)
        case .modal(.commandIntercepted(_, .cancelled(let reason))):
            Log.warning("modal cancelled: \(reason)")
        case .intentRejected(let intent, let reason):
            Log.info("flow rejected \(intent) because \(reason)")
        default:
            continue
        }
    }
}
```

从 5.0 开始,每个 `*Configuration` 只有一个类型化 `onEvent` 回调。
同步交付时对 `NavigationEvent`、`ModalEvent` 或 `FlowEvent` 使用 `switch`,
异步迭代则使用 `events`。旧的逐事件回调已删除且不提供兼容 shim。
Flow 回调除了自己的 `.pathChanged` / `.intentRejected` 外,还会收到
`.navigation(...)` / `.modal(...)`。

### 背压 (Backpressure)

每个 store 通过每订阅者一个的 `AsyncStream.Continuation` 将每个事件 fan-out
给每个订阅者。为了在负载下限制每订阅者的队列,每个 store 在其配置中
接受一个 `eventBufferingPolicy`:

- `.bufferingNewest(1024)`(默认)— 每订阅者保留最近 1024 个事件,缓冲区
  填满时丢弃较旧的事件。为现实的导航突发量设计,同时保持保留的工作集有界。
- `.bufferingOldest(N)` — 每订阅者保留最早的 N 个事件,缓冲区填满时丢弃
  较新的事件。
- `.unbounded` — 缓冲每个事件直到订阅者排空它。用于你控制生命周期且
  需要确定性、无损排序的测试 harness 或短命订阅者。

```swift skip doc-fragment
let store = try NavigationStore<HomeRoute>(
    initialPath: [.list],
    configuration: NavigationStoreConfiguration(
        eventBufferingPolicy: .bufferingNewest(2048)
    )
)
```

`ModalStoreConfiguration.eventBufferingPolicy` 控制 `ModalStore.events`。
`FlowStoreConfiguration.eventBufferingPolicy` 控制 flow-level `FlowStore.events`
fan-out,而 `FlowStoreConfiguration.navigation.eventBufferingPolicy` 和
`FlowStoreConfiguration.modal.eventBufferingPolicy` 控制被包装的内部 store stream。
丢弃是静默的 — 如果你的分析 pipeline 必须区分"无事件发生"和"事件被缓冲外丢弃",
请用 `.unbounded` 订阅并自行调节节奏。

完整契约文档化于
[`Event-Stream-Backpressure`](Sources/InnoRouterCore/InnoRouterCore.docc/Articles/Event-Stream-Backpressure.md)。

## 路线图

在 [`Docs/competitive-analysis-and-roadmap.md`](Docs/competitive-analysis-and-roadmap.md)
中跟踪。随着 P3 抛光集群发货,P0 / P1 / P3 backlog 已空。公开 OSS 线从 4.0 基线开始;
有关已发货的表面变更,请参阅 [`CHANGELOG.md`](CHANGELOG.md)。

- [x] **P2-3 UIKit 逃生口** — 4.0.0 OSS 发布拒绝。InnoRouter 保持仅 SwiftUI
      定位姿态;需要 UIKit / AppKit 适配器的团队可以在 InnoRouter 之外组合这些表面。
- [x] **Debounce 语义** — 在 4.0.0 中作为 `DebouncingNavigator` 发货,
      围绕 `NavigationCommandExecutor` 的 `Clock` 可注入包装器。同步
      `NavigationCommand` 代数保持无 timer。

## 采用者

InnoRouter 处于其公开采用曲线的开始。如果你在生产中发布 InnoRouter,请打开
一个 PR,将你的项目附加到下面的列表 — 如果还不可能使用公开名称,通用描述符
(`a finance app at $company`)也可以。采用者信号有助于潜在用户衡量成熟度。

- _你的项目在这里。_

[`Examples/SampleAppExample.swift`](Examples/SampleAppExample.swift) 文件展示了
完整的标题特性表面 — 带认证 gating 的深链接 pipeline、FlowStore push+modal
投影,以及 DebouncingNavigator 搜索去抖 — 组合到一个自包含的权限类中。

## 贡献

有关分支、提交约定、公开 API 变更规则和 macro 测试要求,参见
[`CONTRIBUTING.md`](CONTRIBUTING.md)。
安全发现遵循 [`SECURITY.md`](SECURITY.md) 中的私有流程。
参与应遵循 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)。

## 许可

MIT
