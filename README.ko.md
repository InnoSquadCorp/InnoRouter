# InnoRouter

SwiftUI를 위한 macro-first typed navigation 라이브러리입니다.

InnoRouter 6는 하나의 `@Router` enum을 하나의 navigation 모델로 연결합니다.

- `RouterState<Route>`: 전체 화면 구조를 담는 단일 value source of truth
- `RouterAction<Route>`: 유일한 점진적 요청 언어
- `RouterPlan<Route>`: 링크·복원이 공유하는 정확한 목표 상태
- `RouterStore<Route>`: reduce, policy prepare, atomic commit의 단일 권한
- `RouterHost`, `RouterTabHost`, `RouterSplitHost`: native SwiftUI container

> **6.0 상태:** 6.0.0을 배포했습니다. 6.1–6.3으로 계획했던 기능은 첫 태그
> 이전에 모두 포함했으므로 배포 이후 SemVer를 깨지 않았습니다. 이제 breaking
> 변경은 다음 major 릴리스를 대상으로 합니다.

[English](README.md) · [6.0 전략](Docs/v6-functional-strategy.md) ·
[5.x 마이그레이션](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)

## 요구 사항

- Swift 6.3+
- `swift-tools-version: 6.3`
- iOS 18+, iPadOS 18+, macOS 15+, tvOS 18+, watchOS 11+, visionOS 2+

## 설치

6.0.0 공개 후 하나의 runtime product만 추가합니다.

```swift skip package-manifest-fragment
.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "6.0.0")

.product(name: "InnoRouter", package: "InnoRouter")
```

`InnoRouterTesting`과 `InnoRouterInspector`는 선택형 개발 도구입니다. 5.x의
세분화된 runtime, macro, effect, scene, spatial product는 6.0 계약에서 제거됩니다.

## 30초 Quick Start

route enum과 macro-first host로 시작하세요.

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case settings
    case detail(id: String)

    var destination: some View {
        switch self {
        case .settings:
            Text("설정")
        case .detail(let id):
            Text("상세 \(id)")
        }
    }
}

struct HomeView: View {
    @EnvironmentRouter(AppRoute.self) private var router
    @EnvironmentRouterState(AppRoute.self) private var routerState

    var body: some View {
        Button("상세 열기") {
            router.go(.detail(id: "42"))
        }
        .disabled(routerState.presentation != nil)
    }
}

struct AppRoot: View {
    var body: some View {
        RouterHost(AppRoute.self) {
            HomeView()
        }
    }
}
```

기본적으로 host가 store를 소유합니다. 복원, 정책, inspector, 직접 상태 관찰이
필요한 앱 경계에서만 `RouterStore`를 만들어 주입합니다.

## 하나의 runtime 모델

```swift skip doc-fragment
let store = AppRoute.makeRouterStore()
let outcome = await store.perform(.push(.detail(id: "42")))
let snapshot = try await store.snapshot(using: RouterSnapshotCodec(currentVersion: 1))
```

모든 요청은 `reduce → prepare → commit`을 거칩니다. 정책 거절, 취소, stale
prepare, 잘못된 action은 기존 상태를 바꾸지 않습니다. 성공할 때만 완성된
`RouterState` 하나를 대입하고 revision을 한 번 올립니다.

원자적인 stack 변경에는 `goIfNeeded`, `backOrGo`, `replaceTop`을 사용합니다.
짧은 시간에 요청이 몰리는 진입점은 `RouterRequestKey`와 `keepFirst` 또는
`replacePending`을 조합할 수 있으며, 관련 없는 요청의 FIFO 순서는 유지됩니다.
policy가 `deferRequest`를 반환하면 외부 결정을 기다리는 동안 실행 lane을 비우고,
이후 기존 revision을 확인해 재개하거나 현재 상태에 명시적으로 rebase할 수 있습니다.

tab·split 하위 트리는 `RouterScope`로 관찰하고 요청합니다. scope는 안정적인
projection과 forwarder이며 또 다른 mutable store가 아닙니다.

`@EnvironmentRouterState`는 macro-first 읽기 surface입니다. read-only이며
Observation과 연결된 `RouterStateReader`에서 `path`, `canGoBack`, presentation,
tab selection, badge처럼 화면이 실제로 필요한 값만 읽습니다.

독립 기능 패키지는 자체 route enum만 선언하고 앱 모듈에 의존하지 않습니다. 앱의
조립 지점에서 associated-value case에 `@FeatureRoute`를 붙이면 생성된 매핑이 자식
액션과 상태를 부모 저장소에 연결합니다.

```swift skip doc-fragment
@Router
enum AppRoute {
    @FeatureRoute("account.primary")
    case account(AccountRoute)

    var destination: some View {
        RouterFeatureHost(AppRoute.Feature.account) {
            AccountRoot()
        }
    }
}
```

`AccountRoot` 안에서는 기존 `@EnvironmentRouter(AccountRoute.self)`와
`@EnvironmentRouterState(AccountRoute.self)`를 그대로 사용합니다. 요청은 부모와
같은 policy, queue, transition ID, revision, commit을 사용하며 자식 store를 만들지
않습니다. 한 기능 projection에는 그 기능 route만 있어야 하므로 부모 route가 섞이면
명시적으로 실패합니다. 앱 window와 immersive space 생성·종료 권한은 부모 조립
지점에 남습니다.

생성된 매핑은 `AppRoute.Feature.account`, 구조 메타데이터는
`AppRoute.routerFeatureCatalog`에 있습니다. 중첩 generic router를 포함해 재귀
feature payload에는 부모 route의 `Self`를 사용할 수 있습니다. 연관값이 있는
`routerFeatureCatalog` case는 정상 overload이며, 연관값이 없는 case만 생성
메타데이터와 충돌합니다.

자동 복원은 versioned codec과 앱이 선택한 저장소를 명시적으로 연결합니다.

```swift skip app-lifecycle-fragment
let driver = RouterRestorationDriver(
    store: store,
    codec: try RouterSnapshotCodec(currentVersion: 1),
    storage: RouterFileSnapshotStorage(fileURL: snapshotURL)
)

RouterHost(store: store) { HomeView() }
    .routerStateRestoration(driver)
```

driver는 일반 policy pipeline으로 복원하고 commit 저장을 coalesce하며 scene이
inactive가 될 때 flush합니다. activation 예약 시점에 관찰과 시작 revision을 확정해
snapshot load 중 들어온 최신 navigation을 덮지 않습니다. 중단된 worker와 caller
소유권은 이후 activation을 변경할 수 없습니다. cloud sync는 계속 앱이 선택하는 별도
책임입니다.

삭제되었거나 현재 앱에서 유효하지 않은 route가 snapshot에 있을 수 있다면
`restorePartially(from:using:validator:validationTimeout:)`를 사용합니다. decode와
migration 뒤 앱이 각 route를 유지·제거·대체하도록 판단하고, 시작 revision을 기준으로
exact plan 하나만 commit합니다. stack 중간 route가 무효면 의존 suffix만 제거하고
유효한 형제와 현재 scene은 유지합니다. 보고서에는 위치와 앱 소유 사유 코드만 있고
route 값은 없습니다. 기존에 비어 있지 않던 stack의 route가 전부 제거되면 기본적으로
실패합니다. 앱이 `RouterPartialRestorationValidator(fallback:validate:)`에 fallback을
명시한 경우에만 그 route를 한 번 더 검증한 뒤 plan에 넣습니다.

아래 명시적 탭 topology API는 **6.1용 미출시 추가 기능**입니다.
현재 배포된 6.0.0 패키지에는 포함되지 않습니다.

복원은 기본적으로 exact입니다. snapshot이 말하는 상태를 그대로 적용하므로, 해당 탭이
생기기 전에 저장된 snapshot에는 그 탭의 branch가 없고 탭은 도달 불가능한 상태로
남습니다. 지금 앱이 렌더링하는 탭을 추가하려면 topology를 명시합니다.

```swift skip app-lifecycle-fragment
let topology = try RouterTabRestorationTopology(of: AppRoute.self)

try await store.restore(from: data, using: codec, tabTopology: topology)
```

snapshot에 있는 scope는 path·presentation·badge를 그대로 유지합니다. 없는 scope는 빈
상태로 만들며 route나 badge를 임의로 만들어 넣지 않습니다. topology에 없는 branch는
현재 scope 뒤에 orphan으로 보존해 이후 catalog가 다시 도달할 수 있게 합니다. 이런
store는 `RouterTabHost(store:catalog:allowingOrphanedBranches:)`로 렌더링합니다.
topology에 없는 selection은 첫 번째 scope로 대체됩니다. 같은 parameter가
`restorePartially`에도 있으며, 이 경로에서는 보정이 검증보다 먼저 실행되어 앱이 실제로
적용될 후보를 그대로 검증합니다. `RouterRestorationDriver.init`에도 있으며 topology는
해당 driver의 생명주기에 속합니다. `RouterSnapshotRecoveryPolicy.use`가 반환한 상태는
앱이 정한 최종 답이므로 보정하지 않습니다.

탭 보정 복원은 시작 revision을 캡처하므로 디코딩 중 새 이동이 commit되면 stale로
거절합니다. 공개 보정 함수는 입력 상태를 검증하고 현재 탭의 node가 stack이 아니면
실패합니다. 부분 복원의 `report.topologyChanges`에는 추가된 scope, 순서, selection
변경을 payload 없이 기록합니다. 보고서는 후보에 대한 설명이며 실제 적용 여부는
`transition`으로 확인합니다. 6.1 이전 보고서는 구조 변경이 없는 값으로 디코딩됩니다.

## tab과 split

tab root에만 `@TabItem`을 붙이고, 일반 destination case를 같은 enum에 둡니다.

```swift skip doc-fragment
@Router
enum AppRoute {
    @TabItem("홈", systemImage: "house")
    case home

    @TabItem("설정", systemImage: "gear")
    case settings

    case detail(id: String)

    var destination: some View { /* exhaustive switch */ }
}

RouterTabHost(AppRoute.self, initial: .home)
```

macro가 case 이름 기반 scope ID를 생성하므로 번역이나 tab 순서 변경이 복원된
branch history를 손상시키지 않습니다. `@TabItem`은 선택 상태 system image와 native
search tab role도 선언할 수 있습니다.

`RouterSplitHost`는 sidebar와 detail의 독립 history를, `RouterThreeColumnSplitHost`는
content까지 포함한 세 개의 독립 history를 유지합니다. visibility와 compact column
선호도는 `RouterSplitState`에 들어가며 같은 system-origin pipeline으로 동기화됩니다.
사용자 정의 column ID는 throwing `RouterTwoColumnSplitLayout` 또는
`RouterThreeColumnSplitLayout`으로 구성하므로, 중복·빈 값·존재하지 않는 column
topology는 host를 만들기 전에 거절됩니다.

## 명시적인 플랫폼 adaptation

`RouterPlatformCapabilities.current`는 현재 Apple 플랫폼이 실제로 제공하는 router
기능의 공개 계약입니다. 요청한 presentation style이나 option을 native UI로 그대로
표현할 수 없으면 host도 같은 계약으로 fallback을 결정합니다. 이때 조용히 동작을
바꾸지 않고 중복 제거된 `RouterEvent.platformAdapted`를 내보내며, 선택형 Inspector는
payload를 노출하지 않는 설명을 기록합니다. CI는 iPhone, iPad, Apple TV, Apple Watch,
Apple Vision simulator에서 이 계약을 실행하고 macOS package suite는 native process로
검증합니다.

## deep link와 exact plan

`@DeepLink`는 literal origin allowlist를 사용하는 fail-closed parser를 생성합니다.
`RouterLinkPipeline`은 단일 route나 전체 matcher 결과를 `RouterPlan`으로 만들며,
transaction과 복원도 같은 plan을 사용합니다. 인증 대기는 부분 이동 없이 정확한
plan 전체를 보관합니다. `RouterPendingLinkSlot`은 교체·취소·재개를 명시적으로
다루며, 재개가 정책에서 거절되면 기본적으로 pending 값을 유지합니다.
프로세스 종료 뒤에도 이어야 한다면 `RouterPendingLinkPersistenceDriver`가 앱이 고른
저장소에 versioned 값을 저장합니다. 느린 복원은 더 최신 in-memory link를 덮지 않습니다.

`@Router`에 `inspectorCatalog: true`를 지정하면 실제 resolver와 같은 우선순위로
payload 없는 `DeepLinkRouteCatalog`를 생성합니다. `explainDeepLink(_:)`는 인증이나
navigation을 실행하지 않고 origin 거절, path 불일치, parameter 변환 실패를 구분합니다.
catalog 항목에는 안정적인 ID, 선언 namespace, feature path, parameter schema가 있습니다.
parameter 순수성은 실제 metatype으로 판별하므로 표준 타입 이름을 가린 custom 타입은
읽기 전용 분석에서 실행하지 않습니다. feature route URL은 자식 선언의 origin을,
부모 직접 route URL은 부모 origin을 각각 유지합니다.
`RouterInspectorDeepLinkView(store:)`는 순수 reducer로 payload 없는 구조 diff를 먼저
보여주며, 별도 실행 버튼을 눌렀을 때만 URL을 resolve해 일반 store policy queue로 보냅니다.

## 제한형 이동 이력

앱 수준의 뒤로·앞으로·이름 있는 checkpoint가 필요한 곳에만 `RouterHistory`를
연결합니다. stack path, tab/split 선택, 현재 존재하는 scene 내부 이동만 기록합니다.
일반 policy와 exact plan을 거쳐 applied 또는 unchanged일 때만 cursor가 이동하며,
뒤로 간 후 새 이동이 성공하면 forward 기록을 제거합니다. badge와 열린 presentation은
보존하고 modal 아래 path 변경은 거절하며 과거 scene을 열거나 현재 scene을 닫지
않습니다. commit은 동기적으로 관찰하고 deferred 이동과 거절을 구분합니다. 계정·문서
경계의 `reset(sessionKey:)` 또는 `stop()`은 대기 중이던 이전 이동과 승인을 무효화합니다.
필요하면 snapshot 복원과 같은 부분 복원 validator를 history에도 지정할 수 있습니다.

## 값을 반환하는 presentation

```swift skip doc-fragment
@Router
enum AppRoute {
    @PresentationResult(Bool.self)
    case settings
    // destination...
}

let request = AppRoute.Presentation.settings
switch await router.present(request) {
case .value(let saved): print(saved)
case .dismissed: break
case .cancelled: break
case .rejected(let reason): print(reason)
}

// 표시된 destination 내부
try await router.finishPresentation(request, returning: true)
```

생성된 request가 표시와 완료 양쪽의 결과 타입을 컴파일 시점에 검사합니다.
presentation UUID와 하나의 완료 요청이 예약 값을 소유하므로 오래된 완료가 교체된
presentation을 닫지 못합니다. 사용자 dismiss, 호출자 취소,
route/result mismatch, 정책 거절을 구분합니다. sheet, cover, popover는 snapshot에
보존되는 detent, drag indicator, compact adaptation, dismiss 옵션을 공유합니다.

## scene, 시스템 진입점, 기존 앱 연결

parameterless route case에 `@Scene(.window)` 또는 `@Scene(.immersiveSpace)`를 붙이고,
SwiftUI scene 선언 옆에 `RouterSceneDriver`를 한 번 설치합니다. 일반 window는
`WindowGroup(id:for: UUID.self)`로 선언해 `RouterWindow.id` 하나가 정확한 native
window 인스턴스 하나를 열고 닫게 합니다. scene content에
`routerWindowLifecycle(_:store:)` 또는 `routerImmersiveSpaceLifecycle(_:store:)`를
붙이면 사용자 dismiss가 같은 store에 반영되고 정책 거절 시 native scene을 복구합니다.
App Intent와 Handoff는
`RouterOpenURLIntentBuilder`, `routerHandoff`, `continueRouterHandoff`를 통해 동일한
canonical URL/plan 계약을 사용합니다. Handoff는 시스템 제약에 맞춰 HTTP(S)
universal link만 받습니다. 기존 UIKit/AppKit 앱은 `RouterUIKitBridge` 또는
`RouterAppKitBridge`로 동일 store를 host하며 두 번째 stack을 만들지 않습니다.
`RouterShortcutCatalog`는 앱이 소유한 App Intent와 stable route ID를 공유하고,
`RouterObservability`는 payload 없는 OSLog/metrics hook을 제공합니다. 실제 분석
수집·전송은 framework가 수행하지 않습니다.

각 window와 immersive space는 application state 안에서 독립적인 recursive node를
소유합니다. macro가 생성한 `AppRoute.Scene` catalog는 window/immersive 요청 타입을
구분하고, `RouterWindowHost`와 `RouterImmersiveSpaceHost`가 정확한 scene-local
history를 렌더링합니다.

## 적합한 surface 고르기

| 필요 | 6.0 surface |
| --- | --- |
| local stack과 presentation | `@Router` + `RouterHost` |
| 독립 branch history를 가진 tab | `@Router` + `@TabItem` + `RouterTabHost` |
| 2열 또는 3열 구성 | `RouterSplitHost` / `RouterThreeColumnSplitHost` |
| 외부 권한 또는 async 정책 | `RouterStore` + `RouterStoreConfiguration` |
| idempotent 또는 coalesced 요청 | 원자적 environment action + `RouterRequestKey` |
| 외부 승인이 필요한 transition | `RouterPolicyDecision.deferRequest` |
| 반응형 read-only UI 상태 | `@EnvironmentRouterState` |
| URL에서 완전한 목표 상태 생성 | `RouterLinkPipeline` + `RouterPlan` |
| 인증 대기 URL 재개 | `RouterPendingLinkSlot` |
| 인증 continuation 영속화 | `RouterPendingLinkPersistenceDriver` |
| versioned 자동 복원 | `RouterRestorationDriver` + 앱 선택 저장소 |
| host 없는 transition 테스트 | `InnoRouterTesting.RouterTestStore` |
| window와 immersive scene | `@Scene` + `RouterSceneDriver` |
| App Intent 또는 Handoff | `RouterOpenURLIntentBuilder` / `continueRouterHandoff` |
| shortcut route catalog | `RouterShortcutCatalog` |
| payload-safe 로컬 진단 | `RouterObservability` |
| UIKit 또는 AppKit 점진 도입 | `RouterUIKitBridge` / `RouterAppKitBridge` |
| 상태 트리, diff, 안전한 replay | `InnoRouterInspector` |

## 개발 도구

`RouterTestStore`는 production reducer와 policy를 그대로 실행하고 transition context,
exact plan, snapshot/restore까지 검증합니다. `RouterInspectorRecorder`는 검색 가능한
bounded timeline, 상태 트리, 구조 diff, JSON import/export, 단계 이동, session 비교,
bookmark, correlated timing, 임의 A/B 비교, rejection breakpoint, 순수 reducer replay
preview를 제공합니다. native 화면은 JSON snapshot과 버전이 있는 진단 번들을 가져오고,
framework/platform 정보가 포함된 번들을 내보냅니다. 앱이 `InnoRouterTesting`도
가져오면 `RouterInspectorScenarioController.routerScenario(store:)`로 기록 시작·진행률·
중지·완전성·원본 가져오기/내보내기를 명시적으로 연결할 수 있습니다. replay는 live store를 변경하지 않으며 route payload는 기본적으로 노출하지
않습니다. 시나리오 실패는 decoder나 앱 오류 원문 대신 payload 없는 종류로 표시하고,
가져오기 실패 뒤에는 이전 raw fixture를 내보낼 수 없게 제거합니다.

Inspector의 조작 버튼, 접근성 레이블, 일반 상태·실패 안내는 영어와 한국어·일본어·
중국어 간체/번체·스페인어·프랑스어·독일어·이탈리아어·브라질 포르투갈어·러시아어·
아랍어·힌디어·인도네시아어·베트남어·태국어로 제공합니다. 화면을 다시 만들지 않아도
SwiftUI locale 변경을 반영하며, 미지원 언어는 영어로 표시합니다. 진단 식별자와
앱이 제공한 내용은 번역하지 않습니다. 언어 지정 방법, 의미 검토 기준, 검증 범위는
[Inspector 다국어 안내](Docs/inspector-localization.md)를 참고하세요.

`RouterActionSequence`는 액션마다 transition context를 저장하고 `RouterTestStore`로
순서대로 재생합니다. 원래 initial state와 dependency를 제공하면 출처와 요청 메타데이터에
따른 policy 동작을 검증할 수 있습니다. 이 fixture에는 앱 payload가 포함되므로 공유 전에
확인해야 합니다. `RouterObservability.signposts`는 payload 없이 Instruments 전환 구간을
기록하고 adapter 수명이 끝날 때 진행 중인 구간도 닫습니다.

`RouterScenarioRecorder`는 reduction 전 거절과 unchanged를 포함해 요청·시작·terminal
경계를 같은 actor에서 동기적으로 기록하므로 완료 직후 stop해도 기록을 놓치지
않습니다. fixture v7은 route schema, 실행 환경, 의존성/효과 capability, 시작 revision,
논리 요청별 submit/wait/cancel/terminal, 가상 시간 이동, 명시적 deferral 결정을
저장합니다. 첫 요청 전에 metadata와 전체 initial state 호환성을 검사하고 캡처 deferral
ID를 새 실행 ID에 매핑합니다. 실패나 취소가 반환되기 전에 replay가 소유한 요청과
deferral만 취소하고 terminal을 회수합니다. deferral은 recorder의
`resolveDeferred`를 통해 결정해야 하며, 누락된 제어 사건·용량 초과·미종료 요청은
통과 가능한 자료로 추측하지 않고 불완전 fixture로 표시됩니다.
관찰 결과와 `RouterScenarioExpectation`은 분리되어 있어 개발자가 각 기대
state·revision·terminal 결과를 채우기 전에는 테스트 소스를 만들 수 없습니다.
완료된 자료는 `RouterScenarioSourceGenerator.generateFiles`가 별도 JSON fixture와
Swift Testing 소스를 만들며, `RouterScenarioRunner`, 실제
`RouterTestStore`, 상대 revision, 앱이 제공한 policy factory를 사용하는 Swift Testing
코드로 생성합니다. 겹친 busy/queue 결과, 취소, timeout과 승인은 순차 send로
평탄화하지 않고 기록한 제어 사건 순서대로 재현합니다. 기본 Inspector 공유에는 판정과
선언된 route pattern만 포함되고 원본 URL/fixture는 별도 명시적 내보내기 동작이 필요합니다.

## OSS 릴리즈 및 SemVer 계약

공개된 5.x line은 같은 major 안에서 source stability를 유지합니다. InnoRouter
6.0.0은 의도적인 breaking reset입니다. 독립 store·intent·plan·coordinator handoff와
세분화 product는 외부 import 대상에서 제거됩니다. `6.0.0-rc.1` 같은 prerelease는
GitHub `prerelease=true`로 게시하며, bare SemVer 태그는 package·문서·platform·API·
consumer 게이트를 모두 통과한 뒤에만 게시합니다.

## 문서

- [기능 전략](Docs/v6-functional-strategy.md)
- [API 수렴](Docs/v6-api-convergence-spike.md)
- [기능 명세](Docs/functional-expansion-spec.md)
- [구현 계획](Docs/functional-expansion-technical-plan.md)
- [6.0.0 릴리스 체크리스트](Docs/6.0.0-release-checklist.md)
- [5.x에서 이전](Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md)
- [변경 기록](CHANGELOG.md)

## Quality 게이트

```bash
swift test --jobs 2
./scripts/check-public-api.sh
./scripts/check-docs-consistency.sh
./scripts/check-docs-code-blocks.sh
./scripts/principle-gates.sh
```

릴리즈 검증에서는 지원하는 모든 Apple platform과 후보 revision에 고정한 downstream
consumer build도 추가로 수행합니다.

## 라이선스

MIT. [LICENSE](LICENSE)를 확인하세요.
