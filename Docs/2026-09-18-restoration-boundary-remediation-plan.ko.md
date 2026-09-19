# InnoRouter 복원 경계 재설계·회귀 수정 계획

> 2026-09-19 후속: 직접 복원의 decode 경쟁, public 입력/stack 검증 및 검사·증거 공백을
> 추가 확인했다. 아래 9월 18일 완료 기록과 구분해
> [안전성 수정·재검토 기록](review-evidence/2026-09-19-restoration-safety.ko.md)에서
> RBR-AC-006~012를 다시 검증한다. 6.1 발행(T09)은 후속 T10~T13 결과를 확인한 뒤 판단한다.

| 항목 | 내용 |
| --- | --- |
| 문서 상태 | Draft |
| 작성일 / 버전 | 2026-09-18 / 0.3 |
| 기준 소스 | `4451d7af999417d31ec3832d4c9c558d96c9deb7` |
| 회귀 도입 소스 | `102c03ca3a7ee911f44c8d58df2cbea9ac32f840` (미출시) |
| 최근 태그 | `6.0.0` = `f6abef8e` (2026-09-16). 회귀는 이 태그에 **포함되지 않음** |
| 결정 책임자 | 프로젝트 유지관리자(사용자) |
| 검토자 / 승인자 / 승인일 | 미기록 / 미기록 / 미기록 |
| 구현 / 배포 상태 | RBR-T01~T08 완료(로컬 게이트·원격 CI 통과, `main` = `d9f60862`). T09 발행 미착수 |
| 실행 기록 | [복원 경계 재설계 실행 기록](review-evidence/2026-09-18-restoration-boundary-remediation.ko.md) |
| 릴리스 범위 | 명시적 탭 복원 API 추가분만 발행 대상. 유일한 발행 후보는 **6.1.0**이며 6.0.1은 필요하지 않다 |

이 문서는 [기존 탭 복원 계획](2026-09-18-tab-restoration-and-docs-plan.ko.md)의
TRD 요구사항과 [안정화 작업 원칙](6.0.0-stabilization-workflow.ko.md)을 이어받는다.
기존 ID와 과거 실행 결과는 보존한다. 재검토로 발견한 회귀와 검증 공백 때문에
TRD-T02~T06의 관련 완료 판정을 다시 연다. 아래 `RBR-*`는 이번 후속 작업의 ID다.

## 1. 검증된 문제와 범위

### 1.1 회귀의 출시 상태

R1·R2의 원인 코드(`restorationTabBaseline` 저장 프로퍼티,
`RouterTabRestoration.swift`, `prepareRestoredState` 호출부 3곳)는 전부
`102c03ca` 한 커밋에서 생겼다. 이 커밋은 `6.0.0` 태그(`f6abef8e`) 이후의
main 커밋이고 어떤 태그에도 포함되어 있지 않다. **영향받는 사용자는 없다.**

따라서 이번 작업은 출시된 계약의 호환성 복구가 아니라, 미출시 main을 정리한 뒤
기능을 다시 설계하는 일이다. 이 구분이 아래 세 가지를 결정한다.

- 긴급 patch 릴리스가 필요 없다. 6.0.1을 만들 이유가 없고, 실제로 발행될 것은
  `6.0.0` + 신규 additive API = **6.1.0** 하나뿐이다.
- `102c03ca`를 되돌리는 것은 제품 결정이 아니라 공정 단계다. 되돌린 뒤에도
  명시적 탭 복원 기능은 그대로 목표로 남는다(3절 B안).
- `102c03ca`는 신규 public 심볼을 추가하지 않았다. 기존 `restore(from:using:)`와
  `restorePartially`의 **동작**을 바꾸고, 그 동작을 단언하는 downstream 테스트
  (`ConsumerSmoke/Tests/InnoRouterDeveloperToolsExternalConsumerTests/CanonicalPublicAPITests.swift`의
  `tabRestorationReconcilesPublishedTopology`)를 추가했다. 이 테스트는 틀린 계약을
  고정하므로 revert 대상에 함께 포함된다.

`b4d33be6`은 revert 범위가 **아니다**. 해당 커밋은 macro diagnostic, `RouterSplitHost`,
`RouterByteStore`, deep-link expansion 등이 주 내용이고, 탭 관련 변경은 별개 사안이다.
`102c03ca` 이후 `Sources/`·`Tests/`를 수정한 커밋이 없으므로 단일 revert가 깨끗하게 적용된다.

### 1.2 확인된 문제

| ID | 분류 | 현재 확인된 사실 | 개선 목표 |
| --- | --- | --- | --- |
| R1 | 미출시 회귀 | 누락 탭에 초기 branch 전체를 복사해 부분 validator가 제거한 route를 다른 위치에 다시 넣는다. 초기 상태와 snapshot 각각은 유효해도 presentation ID 중복으로 복원 전체가 실패한다. | 초기 topology와 route/presentation payload 분리 |
| R2 | 미출시 회귀 | Store 생성 시점의 topology를 모든 복원에 적용한다. 정상 `.apply` 뒤 자체 저장·복원 결과가 달라지고, tabs→stack 전환 및 앱의 명시적 recovery fallback이 거절된다. | generic exact 복원과 명시적 탭 보정 분리 |
| G1 | 기존 검사 / 준비 누락 | docs gate가 runtime `6.0.0` literal을 요구해 후속 버전 후보에서 실패한다. | 후보·태그 버전과의 실제 일치 검사 |
| G2 | 신규 검사 결함 | `unpublished`도 `published` 부분 문자열 검사에 통과한다. | 상태 필드와 조합을 정확히 검사 |
| V1 | 검증 공백 | 새 탭·딥링크 suite가 ASan/TSan 필터에서 빠져 있다. mounted 테스트는 실제 화면·back·재실행까지 증명하지 않는다. | 인수 기준별 실제 assertion과 실행 증거 연결 |
| C1 | 계약 불일치 | README는 초기 selection, 기존 계획은 catalog 첫 탭으로 fallback한다고 한다. | 새 명시적 탭 복원에서는 catalog 첫 탭으로 통일 |

C1을 catalog 첫 탭으로 정하는 근거는 취향이 아니다. 초기 selection은 이번에
제거하려는 암묵적 store 생성 시점 상태 그 자체이고, 그 값 역시 현재 catalog에
없을 수 있다. 호출자가 전달한 명시적 입력만으로 유도할 수 있는 결정적 값은
catalog의 첫 ID뿐이다.

R1은 초기 branch에 route/presentation이 있을 때의 문제다. 기본 macro host의
빈 초기 branch에서 항상 발생한다고 일반화하지 않는다. 수동 host가 legacy orphan을
거절하는 동작 자체는 `102c03ca` 이전에도 있었다. R2의 회귀 증거는 **유효한 현재 상태를
저장하고 다시 복원했을 때 새 불일치가 생기는 경우**다.

재검토에서는 동일 probe를 `102c03ca` 전·후 모듈에 각각 컴파일해 비교했다. 현재 후보의
전체 644 tests / 80 suites와 상태 경계 대조군 8개는 통과했다(기존 known issue 1건).
정책 거절·부분 복원 취소·stale에서 상태 보존도 확인됐다. 이 결과는 후속 수정의
완료 증거가 아니다. 원본 재현 자료는 `/tmp/innorouter-contract-review.3HdLlF/`에
있으며 T01에서 영구 회귀로 옮긴다. 파일이 없으면 같은 반례를 재현한다.

포함: R1/R2, 원래의 새 탭 missing scope 문제, 직접·driver·부분·Testing 복원,
macro/manual catalog, recovery, 관련 문서·검사·native 검증·배포 준비.

제외: 전체 Store/Reducer 재작성, 새 mutable authority, 탭 이름의 추측 매핑,
자동 orphan 삭제, History/Scene 정책 재설계, 플랫폼·Swift 하한 변경, 타 저장소 변경,
`b4d33be6`의 macro·SplitHost·ByteStore 변경.
이번 요청에서는 계획과 관련 완료 기록의 정정만 수행한다.

## 2. 요구사항 — 사용자가 관찰할 동작

| 요구사항 | 동작 계약 | 기존 기준 |
| --- | --- | --- |
| RBR-FR-001 | 기존 generic restore와 일반 `.apply`는 앱이 지정한 유효한 목표 상태를 그대로 사용한다. 과거 초기 탭을 강제로 넣거나 현재의 root 형태 변경을 금지하지 않는다. 정상 scene 검증·정책은 유지한다. | TRD-NFR-002, FR-005 |
| RBR-FR-002 | 탭 보정은 호출자가 현재 catalog를 명시한 복원에서만 수행한다. host와 복원에 동일한 catalog를 사용하며, Store 생성 시점·현재 state·`R`의 protocol conformance만으로 catalog를 추론하지 않는다. | TRD-FR-005 |
| RBR-FR-003 | 명시적 탭 복원에서 같은 ID의 유효한 stack은 path·presentation·badge를 보존한다. 누락 탭은 path 비움·presentation 없음·초기 badge 주입 없음으로 생성한다. 초기 route payload는 복원 재료가 아니다. | TRD-FR-001 |
| RBR-FR-004 | 명시적 탭 복원에서 유효한 기존 selection은 유지하고, 제거된 selection은 현재 catalog의 첫 탭으로 바꾼다. orphan branch·badge는 보존하되 표시·선택 fallback·기본 detail 딥링크 대상에서 제외한다. | TRD-FR-002, 003 |
| RBR-FR-005 | 앱의 `.use` recovery가 반환한 상태는 앱이 정한 최종 fallback이다. 탭 보정을 다시 적용하지 않고 기존 정책에 전달한다. provenance에 실제 decode 실패와 fallback을 남긴다. | TRD-FR-004, 005 |
| RBR-FR-006 | 부분 복원은 보정까지 끝난 후보의 route를 검증한다. 검증 뒤 route/presentation을 추가하지 않는다. route 변경 보고서와 구조 변경 설명은 최종 후보와 일치하고 payload를 노출하지 않는다. | TRD-FR-001, 004; FR6-042~044 |
| RBR-FR-007 | 변경된 후보는 정상 정책·취소·revision 경로를 한 번 통과한다. 적용 시 1 commit/1 revision, 동일 상태면 unchanged/0 commit, 거절·취소·stale이면 추가 상태 변경 0이다. | TRD-NFR-001, FR-004 |
| RBR-FR-008 | 기존 manual host의 엄격한 throwing 검증은 유지한다. orphan 보존을 허용하는 새 명시적 사용 경로에서도 모든 현재 탭 branch와 catalog 일치를 검증한다. macro catalog로 manual catalog를 덮지 않는다. | TRD-FR-005 |
| RBR-FR-009 | 승인·구현·발행 상태와 기준 SHA/일자를 분리한다. 버전과 metadata는 정확한 값·관계를 검사하고 역사적 6.0.0 발행 기록을 현재 후보 버전으로 덮지 않는다. | TRD-FR-006, 007 |

제약: 공개 product 3개와 기존 OS/Swift 하한을 유지한다. snapshot JSON schema는
변경하지 않는다. 신규 public API는 `6.0.0` 대비 additive여야 한다. 발행된 6.0.0의
공개 심볼을 제거하거나 의미를 바꾸는 변경이 확인되면 6.1.0에 넣지 않는다.
tests는 명시적 barrier, 가상 시간 또는 완료 이벤트와 실패 종료 기한을 사용한다.
View initializer/body가 Store의 복원 설정을 등록·교체하거나 복원 뒤 별도 repair
commit을 보내는 설계는 채택하지 않는다.

## 3. 기술 방향과 대안

`102c03ca` revert는 아래 어느 안을 고르든 먼저 수행하는 공통 선행 단계다.
미출시 코드이므로 revert에는 deprecation, migration note, 사용자용 changelog 항목이
필요 없다. 대안은 "revert 이후 무엇을 만드는가"에 대한 것이다.

| 대안 | 장점 | 한계 / 판단 |
| --- | --- | --- |
| A. revert에서 종료. 탭 변화는 앱의 명시적 schema migration으로만 처리 | 추가 작업·공개 API 없이 6.0 의미를 그대로 유지 | 라이브러리 차원의 안전한 탭 보정을 제공하지 못한다. 부분 복원 validator는 route 단위여서 새로 추가된 탭 ID의 branch를 만들어 줄 수 없고, 최초 missing scope 문제가 그대로 남는다 |
| B. revert 후, 현재 catalog를 받는 명시적 탭 복원을 신규 additive API로 추가 | R1/R2가 구조적으로 재발할 수 없고 원래 missing scope 문제도 해결한다. catalog 소유권과 검증 경계가 호출부에 드러난다 | additive API·consumer·문서 변경이 필요하다. **권장안** |
| C. View에서 현재 catalog 등록 / Store 초기 baseline 갱신 | 기존 restore 호출 모양 유지 가능 | host mount 순서·복수 host·driver 시작 순서에 의존하고 새로운 설정 생명주기가 생긴다. `102c03ca`가 실패한 방식의 변형이다. 채택하지 않음 |

권장안 B를 완성하는 것을 목표로 한다. revert만 완료한 상태에서 탭 복원 개선 전체를
완료했다고 보고하지 않는다.

### 3.1 Catalog 전달과 API 소유권

아래 이름은 API 설계안이며 아직 존재하는 API가 아니다. T03에서 외부 consumer의
컴파일과 공개 심볼 diff로 정확한 signature를 고정한다.

- `RouterTabRestorationTopology`(가칭): 순서 있는 scope ID만 보관하는 불변 값.
  `RouterTabCatalog`에서 생성하고 첫 ID가 fallback이다. route·presentation·badge,
  Store, View, business closure는 보관하지 않는다. SwiftUI 모듈에 두어 Core codec에
  SwiftUI 의존성을 넣지 않는다.
- 기존 restore/partial restore signature는 exact 의미를 보존한다. 새 topology를
  명시하는 overload를 추가하며 기존 overload와 trailing closure 모호성이 없어야 한다.
- driver에는 같은 topology를 명시하는 초기화 경로를 추가한다. topology는 **해당 driver
  생명주기**에만 속한다. 기존 초기화 경로는 exact다. Store의 초기 전체 상태를 캡처하지 않는다.
- macro 소비자는 생성된 `R.routerTabs`로 검증된 catalog를 만들고 host·복원에 같은 값을
  전달한다. manual 소비자는 앱의 실제 catalog를 전달한다. macro expansion 변경 없이
  기존 생성 surface를 우선 재사용한다.
- 기존 manual initializer는 strict 그대로 둔다. 새 명시적 topology를 함께 받는 host
  경로에서는 catalog/topology 일치, 현재 branch 존재와 stack 형태를 검사하고 추가 orphan만
  허용한다. 이 허용을 기존 strict initializer에 몰래 확장하지 않는다.
- catalog를 바꾸는 앱은 이전 driver를 stop하고 새 구성으로 교체한다. 비동기 복원 중
  topology 변경은 정상 `.apply`와 revision 변경으로 표현해 이전 후보를 stale 처리한다.
  변경 없이 같은 Store를 사용하는 generic restore는 driver와 관계없이 exact로 동작한다.
- `RouterTestStore`도 production의 같은 overload를 전달한다. 별도 보정 엔진을 만들지 않는다.

T03 산출물에는 macro 정상 소비, manual strict, manual orphan 허용, host 미부착 직접
복원, driver 교체, 동적 tabs→stack 예제가 모두 있어야 한다. revert된
`tabRestorationReconcilesPublishedTopology` 자리에는 명시적 topology를 전달하는
downstream 테스트를 새로 넣는다.

### 3.2 후보 준비 순서

```text
bytes → codec decode / 명시적 schema migration
  ├─ decode 성공 + exact: decoded state
  ├─ decode 성공 + 명시적 tab topology: 순수 tab 후보 보정
  └─ codec recovery 사용: 앱의 fallback 그대로 (tab 보정 생략)
→ 부분 복원인 경우: 후보 route validator + 검증된 fallback + 변경 보고서
→ 최종 구조/scene 검증 → 정상 policy/취소/revision 검사 → 1회 apply 또는 unchanged
```

부분 복원은 현재 API의 손상·미래 schema 실패 계약을 유지한다. recovery를 새로
묵시적으로 추가하지 않는다. 구조 불일치 오류를 codec decode 오류로 위장해 `.use`를
호출하지 않는다. 탭 보정에 호환되지 않는 root/현재 branch는 명시적인 typed 실패이며
상태를 그대로 둔다. 앱은 별도 migration 또는 새 요청으로 대체한다.

순수 보정은 전달받은 root tab scope만 다룬다. 현재 ID의 stack은 그대로 두고, 없는 ID는
빈 stack을 만든다. catalog 순서 뒤에 orphan을 원래 순서로 붙인다. snapshot badge만
유지한다. window/immersive/split의 payload·순서는 수정하지 않는다. 정상 snapshot에
원래 있던 중복 ID는 기존 구조 검증에서 거절하고, 보정이 새 presentation ID를 복사하거나
임의 재발급해서 충돌을 숨기지 않는다.

부분 복원 보고서의 route 항목에 탭 selection 변경을 억지로 넣지 않는다. T03에서
payload 없는 구조 변경 항목(예: 추가된 scope ID, selection 이전/이후)을 additive로
제공하는 위치를 고정한다. 기존 report initializer/의미는 보존한다.

새 tab-aware 비동기 요청은 시작 revision을 캡처해 후보 준비 중 커밋을 감지한다.
기존 generic restore의 `expectedRevision` 기본 의미는 별도 요구 없이 바꾸지 않는다.
driver의 기존 activation generation·취소·관찰 계약도 그대로 사용한다.

### 3.3 문서와 release 검사

- `check-doc-metadata.py`는 상태를 정확한 필드 값으로 파싱한다. Published가 선언된
  역사적 기록에는 버전·SHA·일자가 있어야 하며, `unpublished`가 Published로 해석되면 실패다.
  Draft+Published처럼 유효한 조합은 허용한다. 실제 발행을 주장하지 않는 새 문서의
  Unpublished 상태까지 금지하지 않는다. 승인 문자열의 존재와 실제 사용자 승인 증거는 구분한다.
- 일반 main 검사는 유효한 SemVer와 Unreleased 구조를 검사한다. 발행 검사는 전달받은
  후보/tag version, runtime version, 해당 changelog section의 일치를 검사한다.
  `6.0.0` literal을 `6.1.0` literal로 교체하는 것으로 끝내지 않는다.
- 정상/오류 fixtures: patch·minor·prerelease 후보, 버전 불일치, 부정/유사 단어,
  중복·누락 상태 필드, 모순된 발행 metadata, API TSV drift.
- README 양 언어와 public DocC에 exact/tab-aware/recovery/manual 예제를 맞춘다.
  `102c03ca`가 추가한 암묵적 보정 서술은 revert와 함께 사라지므로, 새 예제는 명시적
  topology 기준으로 다시 쓴다. 새 API를 사용한 예제의 최소 버전은 `6.1.0`으로 표기한다.
  과거 6.0.0 발행 사실은 유지한다.

## 4. 순차 작업과 변경 파일

T01의 실패를 먼저 기록하고 T02에서 되돌린 뒤 신규 설계로 이동한다. 커밋 순서는
작업 순서와 다르다. T01의 반례는 revert 뒤에 통과하는 형태로 커밋해 main이 빨간
상태를 거치지 않게 했고, revert 이전 실패 사실은 실행 기록에 남겼다.

| 작업 | 수행 내용 / 주 파일 | 완료 조건 |
| --- | --- | --- |
| RBR-T01 | R1/R2 반례와 최초 missing scope 대조군을 `Tests/InnoRouterTests/`의 동작별 suite로 고정. 임시 재현의 입력·기대값·비교 SHA 기록 | 현재 main에서 R1/R2가 의도한 assertion으로 실패. 정상 거절·취소·stale 대조군 통과. setup 오류 제외 |
| RBR-T02 | `102c03ca`를 독립 커밋으로 revert. `RouterTabRestoration.swift` 삭제, `RouterStore.swift`의 `restorationTabBaseline` 제거, `RouterStore+Snapshot.swift`·`RouterPartialRestoration.swift`의 호출부 3곳 제거, 틀린 계약을 고정한 downstream `tabRestorationReconcilesPublishedTopology` 제거 | T01의 R1/R2 반례 통과. missing scope 대조군은 미지원 상태로 되돌아가 의도적으로 실패(보류 표시). 전체 suite와 기존 gate 통과. 공개 심볼 diff 0 |
| RBR-T03 | 명시적 topology/API와 report 설계 확정. `TabCoordinator.swift`, `RouterRestorationDriverTypes.swift`, `ConsumerSmoke` 경계 검증 | B의 모든 소비 예제 컴파일, signature/ownership/error/report 표와 `6.0.0` 대비 공개 API diff 검토 |
| RBR-T04 | 명시적 입력의 순수 변환으로 탭 보정을 **신규 구현**. `RouterStore+Snapshot.swift`의 exact/recovery와 tab-aware 경로 분리 | 초기 payload 재삽입·presentation 충돌·동적 topology·fallback 회귀가 재발하지 않고, 새 탭 missing scope 대조군이 통과로 전환 |
| RBR-T05 | `RouterPartialRestoration.swift`, `RouterStateRestoration.swift`, `RouterTestStore.swift`에 동일 준비 경계 연결. `RouterTabHost.swift`의 명시적 manual 허용 경로와 실제 default link 경로 확인 | 직접/driver/partial/Testing 결과 일치, 최종 후보 validator/report 일치, 정책·취소·stale·driver 교체 통과 |
| RBR-T06 | `RouterTabHostTests`, `RouterDeepLinkHostTests`, `NativeHostRuntimeTests` 보강. 필요 시 기존 `NativeSceneSmoke`에 탭 복원 QA 경로 추가. `sanitizer-smoke.sh`의 ASan/TSan 두 필터에 실제 suite 포함 | 새 suite가 ASan/TSan에서 실제 실행됐다는 로그 확인, 0 failures. QA 경로는 RBR-QA-001로 분리 |
| RBR-T07 | metadata/version script 및 오류 fixtures, README/DocC, API baseline/예산 문서, 기존 TRD 실행 기록 정정 | 정상 fixture 통과/잘못된 fixture 실패, 선택 fallback 계약 일치, 완료 주장과 assertion 일치 |
| RBR-T08 | 최종 코드 후보 고정 후 전체 필수 gate·외부 consumer·지원 플랫폼·coverage·성능 실행. 범위에 맞는 커밋으로 나누고 push 후 동일 SHA 원격 CI 검토 | 알려진 필수 회귀 0, AC별 명령/결과/SHA 연결, 로컬·upstream·원격 SHA 일치 및 필수 CI 성공 |
| RBR-T09 | `6.1.0` version/changelog cut, bare SemVer tag, exact tag consumer, Release/DocC/latest 확인 | tag SHA·runtime·Release·문서·consumer revision 일치. 이 단계 전에는 배포 완료라고 하지 않음 |
| RBR-T10 | 새 직접 복원의 시작 revision 캡처, public state 검증, 현재 stack 및 orphan selection 검증 | S1~S4 실패 반례가 정상 대조군과 함께 통과 |
| RBR-T11 | 구조 변경 보고 및 과거 JSON 호환성, 외부 macro/native URL 경로, decode 중 driver 교체 증거 | AC-006~010의 실제 assertion과 bounded 종료 확인 |
| RBR-T12 | 구현/발행 상태 필드의 정확한 parser와 오류 fixtures, 미출시 API 버전 표시 | AC-011의 부정·미래·누락·모순 반례 거절 |
| RBR-T13 | 후속 후보 전체 gate·지원 플랫폼·sanitizer·commit/push·원격 CI 및 재검토 | 후속 코드 후보와 증거 일치. T09의 발행 여부와 구분 |

T02는 단독으로 main에 올려도 안전하다. 되돌린 상태는 발행된 `6.0.0`의 의미와 같고,
사용자에게 노출된 적 없는 동작만 사라진다. T04~T05는 하나의 논리적 runtime 추가로
통합 검증한다. 커밋은 revert, runtime/API 추가, 회귀·native·검증 도구, 문서·metadata,
release cut을 검토 가능한 단위로 나눈다. 이번 계획 작성에서 commit·push·발행은 실행하지 않는다.

## 5. 인수 기준과 증거 행렬

| 인수 기준 | 요구사항 | 통과 조건 | 작업 / 증거 |
| --- | --- | --- | --- |
| RBR-AC-001 | FR-001 | `.apply`로 탭 삭제/재정렬 및 tabs↔stack 전환 후 자체 저장·exact 복원 결과가 동일. manual strict host의 유효 입력은 계속 유효 | T01, T02, T04 / revert 전·후 API 회귀 |
| RBR-AC-002 | FR-003, 006 | 초기 state에 invalid route/presentation이 있어도 누락 탭은 빈 stack. 초기 ID와 snapshot ID가 같아도 새 충돌 없음. validator 제거/대체 결과가 재삽입되지 않음 | T01, T02, T04, T05 / R1 입력과 보고서 assertion |
| RBR-AC-003 | FR-002, 003 | 명시적 catalog의 탭 추가/이름 변경 뒤 새 탭 선택·push·back 성공. rootStack에서 만든 Store가 나중에 tabs가 된 경우도 전달 catalog에 따라 동작 | T04~T06 / macro consumer·host |
| RBR-AC-004 | FR-003, 004 | 동일 ID의 path/presentation/badge 및 window/immersive 상태 보존. orphan 유지. 제거된 selection은 현재 catalog 첫 탭, 반복 저장·복원은 동등 | T04~T06 / codec·실제 파일 round trip |
| RBR-AC-005 | FR-005 | 손상 snapshot의 `.use`가 지정한 유효 rootStack/tab fallback이 그대로 정책에 전달됨. provenance 정확, 정책 거절이면 상태/revision 유지 | T02, T04, T05 / recovery 대조군 |
| RBR-AC-006 | FR-006, 007 | topology 보정 뒤의 모든 route를 검증하고 보고서와 최종 후보가 일치. 유지·제거·대체·검증된 fallback·timeout 각각 검사 | T05 / 부분 복원 suite |
| RBR-AC-007 | FR-007 | 최종 후보 정책 관찰, 적용 1회/unchanged 0회. 준비 중 새 commit·취소·정책 거절·기본 deferral 재개 stale에서 추가 mutation 없음 | T05 / 명시적 barrier·가상 시간 |
| RBR-AC-008 | FR-002, 008 | macro 및 명시적 manual catalog 결과 일치. 기존 manual strict는 mismatched/orphan 입력을 계속 거절. 새 opt-in host는 현재 branch 누락을 거절하고 orphan만 허용 | T03, T05 / positive/negative consumer |
| RBR-AC-009 | FR-002, 007 | host mount 전 직접 복원 가능. driver catalog 교체/stop 뒤 예전 worker가 새 구성을 commit하거나 observer를 되살리지 않음 | T05 / lifecycle boundary |
| RBR-AC-010 | FR-001~008 | production/TestStore/외부 macro 소비자의 결과 일치. ASan/TSan 로그에 새 suite·테스트 이름이 존재하고 0 failures. 별도 select closure나 yield 횟수로 host 동작을 대신하지 않음 | T05, T06, T08 |
| RBR-AC-011 | FR-009 | 유효 lifecycle 조합·patch/minor/prerelease fixtures 통과. unpublished 오인·중복/모순 metadata·버전/TSV mismatch 실패. 기존 TRD 완료 기록을 증거 수준에 맞게 정정 | T07 / script fixture exit·문서 대조 |
| RBR-AC-012 | FR-001~009 | `principle-gates.sh --platforms=all`, package/macro/API/DocC/lint/consumer, 지원 플랫폼 runtime, coverage·성능 gate를 동일 후보로 통과. 정확한 push SHA CI 성공 | T08 / candidate manifest |
| RBR-AC-013 | FR-009 | 확정 `6.1.0` tag의 exact consumer와 runtime version·Release·versioned DocC·latest가 일치 | T09 / 실제 원격·URL 증거 |

표의 `FR-*`는 `RBR-FR-*`를 뜻한다. 성공 기준은 R1/R2 및 원래 missing scope의 재현
실패 0건, 위 필수 AC의 증거 누락 0건이다. 테스트 개수나 coverage 증가 자체는 성공 기준이 아니다.

### 5.1 수동 QA 체크리스트 (비차단)

아래 항목은 자동화된 필수 AC가 아니다. 실행 환경이 있을 때 수행하고 결과를
증거로 남기되, 미실행이 릴리스를 차단하지 않는다. 자동화 불가능한 항목을 필수
행렬에 넣으면 "증거 누락 0건" 기준이 영구히 충족될 수 없기 때문이다.

| 항목 | 내용 | 작업 |
| --- | --- | --- |
| RBR-QA-001 | macOS 및 iPhone/iPad에서 복원→새 탭 선택→실제 detail 표시→native back→tab-root/detail URL 수신→파일 저장→프로세스 재실행. native selection·state reader·기본 detail 목적지 일치 확인 | T06 / 실제 host callback·화면 식별자·파일·실행 로그 |

이 경로에서 자동화 가능한 부분(state reader, 기본 detail 목적지, URL 수신)은 T06의
`NativeHostRuntimeTests` 보강이 덮고, 그 실행 증거는 RBR-AC-010이 요구한다.
RBR-QA-001은 실제 화면·native back·프로세스 재실행처럼 자동화되지 않는 잔여분만 담당한다.

기존 TRD-AC-001~010은 위 행렬에 근거를 연결한 뒤에만 다시 닫는다. TRD-AC-011과
RBR-AC-013은 발행 뒤에만 닫는다. 전체 suite와 sanitizer는 필요한 최종 후보에서 실행하며
코드 변경·실패·새 우려가 없으면 같은 검사를 반복해서 완료 신뢰도를 부풀리지 않는다.

## 6. 착수·완료 판단

- T02는 되돌림 gate다. 미출시 코드를 되돌리는 것이므로 제품 결정을 요구하지 않으며,
  T03 이전에 main을 알려진 6.0 의미로 되돌려 놓는 것이 목적이다.
- T03은 API 이름·공개 심볼 수·manual opt-in signature·구조 보고서 모양을 확정하는 설계 gate다.
  결정 책임자는 유지관리자이며, 기술 제안은 B다. 이미 계획에 대한 구현 요청이 주어지면
  그 범위의 additive 설계는 진행하되, breaking 변경이나 범위 확대를 숨기지 않는다.
- Counterexample 점검: 단순 revert 후 최초 missing scope를 미해결로 두고 완료 보고,
  현재 state를 catalog로 간주, View 등록 순서 의존, validator 뒤 payload 삽입,
  orphan 복구 뒤 manual host 불능, rootStack recovery의 강제 tabs 변환, 부정 metadata 통과,
  view 존재만으로 UI 완료 표시는 이 계획의 AC를 통과할 수 없어야 한다.
- 구현 완료·로컬 검증 완료·push/CI 완료·배포 준비 완료·배포 완료를 구분한다. UI 실행 환경이
  없으면 RBR-QA-001은 미실행으로 남기고, 그 사실을 릴리스 노트가 아니라 증거 문서에 남긴다.
- 현재 단계는 **구현 완료, 로컬·원격 검증 완료, 발행 미착수**다. 발행 대상은 `6.1.0` 하나이며,
  발행 시점은 원격 CI 결과를 확인한 뒤 유지관리자가 정한다. 이 저장소에는 아직
  `6.1.0` version cut, tag, push가 없다.
