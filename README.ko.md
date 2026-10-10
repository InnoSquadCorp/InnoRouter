# InnoRouter

[English](README.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [Русский](README.ru.md)

SwiftUI를 위한 매크로 중심의 타입 안전 내비게이션입니다. 하나의 라우트 enum, 재귀 상태 트리, 변경 권한으로 구성됩니다.

현재 안정 버전은 **7.0.0**이며 2026년 10월 8일 공개되었습니다. 태그 커밋은 `33b0da7639105cfa8e6f5acffa3badb91b5e0254`입니다. 이 가이드는 해당 릴리스를 설명하며, 과거 후보 검증 기록은 원래의 범위를 유지합니다.

[Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0) · [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoRouter)

## 요구 사항과 설치

- Swift 6.3+ (`swift-tools-version: 6.3`)
- iOS / iPadOS / Mac Catalyst 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

Package.swift의 의존성과 제품 배열에 각각 추가하세요. `from:`은 호환되는 7.x 업데이트를 허용하며, 정확히 고정하려면 `exact: "7.0.0"`을 사용합니다. 일반 앱은 `InnoRouter`만 import합니다. 선택 제품은 `InnoRouterTesting`, `InnoRouterInspector`입니다.

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "7.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

## 30초 Quick Start

host가 store를 소유합니다. `@EnvironmentRouter`는 액션을 보내고 `@EnvironmentRouterState`는 읽기 전용 UI 상태를 관찰합니다. 둘 다 일치하는 host 아래에서 사용해야 합니다. 외부 store는 앱의 안정적인 소유 경계에 유지하고 `body`에서 다시 만들지 마세요.

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

## 상태, 권한, throwing 초기 설정

`RouterState`는 외부에서 읽기 전용입니다. `RouterStateDraft`를 편집하고 `try build(resourceBudget:)`로 검증한 뒤 `RouterPlan(state:)`를 만드세요. plan은 정확한 목표 상태, `RouterAction`은 점진적 변경입니다. 오직 `RouterStore`가 이동을 commit합니다. `RouterScope`는 하위 트리의 읽기 전용 투영과 액션 전달자입니다.

`RouterStore<AppRoute>()`와 `AppRoute.makeRouterStore()`는 nonthrowing입니다. 초기 상태·경로·설정이 있으면 `try`가 필요합니다. 외부 store의 renderer는 명시적인 `hostDescriptor`가 필요하며 아래 코드는 기본 stack root를 선언합니다. 앱 초기 설정에서 오류를 처리하고 복구 UI를 표시하세요. `try!`나 무관한 빈 상태로 오류를 숨기지 마세요.

```swift skip contextual-fragment
@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

## 결과, 정책, 취소

요청은 reduce → prepare → commit 순서입니다. 적용된 전이는 전체 상태를 한 번 대입하고 revision을 한 번 올립니다. unchanged, rejected, deferred는 후보를 commit하지 않습니다. 네 가지 `RouterOutcome`을 모두 처리하세요. 아래 조각은 main actor에서 위의 `AppRoute`를 사용합니다.

```swift skip contextual-fragment
let store = AppRoute.makeRouterStore()
switch await store.perform(.push(.detail(id: "42"))) {
case .applied(_, _, _, let revision): print("Committed", revision)
case .unchanged: break
case .deferred(_, _, _, let deferral): print("Deferred", deferral)
case .rejected(_, _, _, let reason): print("Rejected", reason)
}
```

정책은 중단 전후에 불변 후보를 검사합니다. 거절·호출자 취소·오래된 준비·잘못된 액션은 commit 상태를 바꾸지 않습니다. `RouterRequestKey`의 `keepFirst` / `replacePending`을 사용할 수 있으며 무관한 요청은 FIFO입니다. 대기 요청, 정책 timeout, deferral의 한도를 명시하세요. `deferRequest`는 실행 레인을 비우고 재개 시 명시적으로 rebase하지 않으면 revision을 검사합니다. 취소를 무시하는 정책이 늦게 반환해도 취소가 우선합니다. `RouterRejectionReason`은 overflow·timeout·만료·취소를 구별합니다.

## 탭, 분할 화면, scope 수명

매개변수 없는 root에 `@TabItem`을 붙이고 일반 destination은 같은 enum에 둡니다. `RouterTabHost`는 탭별 독립 이력을 보존합니다. case 이름을 바꾸기 전에 안정적인 명시 ID를 지정하세요. Codable route 변경에는 별도 migration이 필요합니다. 입력이 있는 tab/split host는 nonthrowing `body` 밖에서 `try`로 만듭니다. `RouterSplitHost`, `RouterThreeColumnSplitHost`는 안정적인 column declaration ID가 필요합니다. `RouterTabCatalog.hostDescriptor()`로 의미를 고정하고 `replaceHost(with:descriptor:context:)`로 topology와 의미를 원자적으로 교체하세요. 소유 하위 트리를 복원·교체하면 이전 scope 권한은 만료되므로 다시 얻어야 합니다. `RouterHost(store:)`는 nonthrowing이며 `validationFailure`와 복구 UI를 제공합니다.

독립 기능 enum은 `@FeatureRoute`와 `RouterFeatureHost`로 합성합니다. 자식의 `@EnvironmentRouter`, `@EnvironmentRouterState`도 부모 store의 정책·큐·revision·commit을 공유합니다. 기능은 전체 하위 트리를 소유해야 하며 부모/자식 route가 섞이면 명시적으로 실패합니다. window와 immersive scene의 소유권은 앱의 합성 root에 둡니다.

[Examples/MacrosExample.swift](Examples/MacrosExample.swift)

## 딥 링크와 인증 대기

scheme과 host는 리터럴 allowlist로 제한하세요. 일치하는 `RouterHost`가 `onOpenURL`을 처리하며 잘못된 입력과 허용하지 않은 origin은 거절합니다. 예제는 example.com의 HTTPS 제품 URL을 받습니다. `RouterLinkPipeline`은 일치 결과를 `RouterPlan`으로 만들며 인증 정책은 부분 이동 없이 전체 목표를 대기시킬 수 있습니다. `RouterPendingLinkSlot`은 교체·취소·재개를 명시하고 `RouterPendingLinkPersistenceDriver`는 앱이 선택한 저장소에 이어갈 정보를 저장합니다. 느린 복원이 최신 대기 링크를 덮지 않습니다. `inspectorCatalog: true`, `explainDeepLink(_:)`로 읽기 전용 진단을 선택할 수 있습니다.

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

## 타입이 있는 presentation 결과

선언·호출자·표시된 화면은 같은 route 타입과 host를 사용해야 합니다. 아래는 완성 앱이 아닌 문맥이 필요한 조각입니다. 생성된 request가 양쪽의 결과 타입을 검사하고 정확한 presentation UUID와 한 번의 완료 요청이 값을 소유합니다. 오래된 콜백이나 호출자 취소는 교체된 화면을 닫을 수 없습니다. 사용자 dismiss·취소·거절·반환 값은 별개입니다. presentation 수명을 넘겨 완료 권한을 보관하지 마세요.

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

## 복원과 이동 이력

`RouterRestorationDriver`와 앱이 선택한 저장소를 유지하고 안정적인 root에 `routerStateRestoration(_:)`을 붙이세요. `RouterSnapshotCodec`에 버전을 지정하고 route/schema 변경의 migration과 복원 결과를 처리합니다. 탭 변경에는 하나의 catalog를 `RouterTabRestorationTopology`, `catalog.hostDescriptor(orphanPolicy: .preserveDormant)`, renderer에 공통으로 사용합니다. dormant branch는 선택 renderer가 될 수 없습니다. 오래된 복원은 최신 이동을 덮지 못합니다. snapshot 기본 한도는 유한한 잠정값이므로 늘리기 전에 측정하세요. 갑작스러운 종료 직전 저장은 보장되지 않습니다.

`RouterHistory`는 exact plan과 일반 정책을 통해 제한된 뒤로/앞으로 이동과 checkpoint를 제공합니다. badge와 presentation을 보존하고 scene을 열거나 닫지 않습니다. 계정·문서 경계에서 `reset(sessionKey:)`을 호출하세요. reset 또는 stop은 중단된 이동을 무효화합니다.

snapshot 영속화에는 Codable route가 필요하며, 앱 payload/schema의 migration은 앱이 정의해야 합니다.

[Tab restoration](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md) · [Examples/TabRestorationExample.swift](Examples/TabRestorationExample.swift)

## Scene, 시스템 연결, 플랫폼 대응

매개변수 없는 `@Scene(.window)` / `@Scene(.immersiveSpace)`와 일치하는 앱 scene 옆에 `RouterSceneDriver`를 설치합니다. window UUID와 `routerWindowLifecycle` / `routerImmersiveSpaceLifecycle` 콜백을 사용하세요. visionOS에서는 `RouterImmersiveSpaceScene`이 native activation identity를 전달합니다. scene마다 같은 store 안에 독립 하위 트리가 있으며 플랫폼별 availability는 그대로 적용됩니다. `RouterPlatformCapabilities.current`가 기능을 설명하고 `RouterEvent.platformAdapted`가 fallback을 알립니다. `RouterUIKitBridge` / `RouterAppKitBridge`도 같은 권한을 사용합니다. `RouterOpenURLIntentBuilder`, `RouterShortcutCatalog`, `routerHandoff`, `continueRouterHandoff`는 URL 계약을 공유하며 Handoff는 HTTP(S)만 허용합니다.

## 테스트, Inspector, 관측

`RouterTestStore`는 host 없이 실제 reducer와 정책을 실행합니다. `RouterActionSequence`는 전이 context를 보존합니다. `RouterInspectorRecorder`는 제한된 payload-redacted timeline, 상태 diff, import/export, 순수 reducer replay를 제공하며 live store를 변경하지 않습니다. import 기본 한도는 8 MiB, 5,000개입니다. `RouterObservability`는 analytics 전송 없이 payload 없는 로그와 signpost를 제공합니다.

`RouterScenarioRecorder`가 실행 제어를 기록하고 `RouterScenarioRunner`가 취소와 deferral까지 재현합니다. fixture v9는 navigation-only v8을 지원하며 더 오래되거나 알 수 없는 형식은 다시 수집해야 합니다. raw fixture에는 앱 payload가 있으므로 명시적으로 export해야 합니다. `RouterScenarioSourceGenerator.generateFiles`에는 개발자가 정의한 기대값이 필요합니다. Inspector의 영어 외 15개 번역은 README 7개 언어와 별도입니다.

[Inspector localization](Docs/inspector-localization.md) · [AI skill: Codex / Claude Code](skills/README.md)

## 마이그레이션과 과거 문서

6.x → 7은 breaking migration입니다. 읽기 전용 상태 draft, throwing 초기 설정, 고정 host 선언, 유한 자원 한도, authorization generation, 수명에 묶인 결과를 확인하세요. 5.x 사용자는 독립 store/intent와 제거된 세분화 제품도 교체해야 합니다. 과거 API를 현재 앱에 복사하지 마세요. 이전 7개 언어 문서는 모두 archive index에서 접근할 수 있습니다.

- [Release 7.0.0](https://github.com/InnoSquadCorp/InnoRouter/releases/tag/7.0.0)
- [DocC 7.0.0](https://innosquadcorp.github.io/InnoRouter/7.0.0/)
- [6.x → 7](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md)
- [5.x → 6](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [Historical translations / 과거 번역 / traducciones históricas / historische Übersetzungen / 历史译本 / 過去の翻訳 / исторические переводы](Docs/Archive/README-translations.md)
- [CHANGELOG](CHANGELOG.md)
- [Navigation reference (English)](Docs/Navigation-Guide.md) · [상세 가이드 (한국어)](Docs/Navigation-Guide.ko.md)

## 검증과 기여

7개 빠른 시작은 API 예제와 핵심 계약 범위를 공유합니다. 정적 검사만으로 Swift 컴파일·DocC 렌더링·native scene 동작·원어민 검토가 입증되지는 않습니다. merge 전에 Apple toolchain 게이트를 실행하세요. `--no-parallel`은 동기 복원 test double로 인한 cooperative pool 고갈을 방지합니다. 같은 scratch 디렉터리에서 SwiftPM 빌드를 동시에 실행하지 마세요.

```bash
python3 scripts/check-readme-translations.py
swift test --jobs 2 --no-parallel
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

[CONTRIBUTING](CONTRIBUTING.md) · [RELEASING](RELEASING.md) · [Automation policy](Docs/automation-policy.md)

## 라이선스와 후원

MIT 라이선스입니다. 기여, 버그 제보, 문서 수정을 환영합니다.

[LICENSE](LICENSE) · [GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) · [Patreon](https://www.patreon.com/15188938/join)
