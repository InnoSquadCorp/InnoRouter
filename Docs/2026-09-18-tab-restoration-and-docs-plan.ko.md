# InnoRouter 탭 복원·문서 정합성 개선 작업계획

> 2026-09-18 후속 재검토: 초기 branch 재삽입·동적 topology/recovery 회귀와 검증 공백으로
> TRD-T02~T06 및 관련 AC 완료 판정을 재개방한다. 아래 실행 결과는 당시 기록이며
> 현재 배포 준비 완료를 뜻하지 않는다. 현재 개선 방향과 완료 조건은
> [복원 경계 재설계·회귀 수정 계획](2026-09-18-restoration-boundary-remediation-plan.ko.md)을 따른다.

| 항목 | 내용 |
| --- | --- |
| 문서 상태 | Draft |
| 작성일 / 버전 | 2026-09-18 / 0.2 |
| 기준 소스 | `b4d33be67ccd8616718f1dafb94093782791e807` |
| 결정 책임자 | 프로젝트 유지관리자(사용자) |
| 검토자 / 승인자 / 승인일 | 미기록 / 미기록 / 미기록 |
| 요청 범위 | 현재 평가에서 발견한 탭 복원 결함과 문서·검사 불일치의 작업계획 |
| 구현 상태 | TRD-T01~T06 구현·로컬 검증 완료 (`102c03ca`); 원격 CI·배포 검토 대기 |
| 배포 목표 | 호환성 검증 후 후속 6.0.x 패치 후보. 버전은 발행 단계에서 확정 |

기존 [아키텍처 계약](../AGENTS.md), [안정화 작업 원칙](6.0.0-stabilization-workflow.ko.md), [배포 가이드](../RELEASING.md)를 따른다. 6.0.0은 이미 배포됐으므로 과거 문서의 “첫 태그 전 breaking 변경 가능” 조건은 이번 작업에 적용하지 않는다. 아래 `TRD-*` 식별자는 이 작업계획에만 속하며 기존 FR6·AC6 번호를 변경하지 않는다.

## 1. 확인된 사실과 목표

### 확인된 사실

| ID | 사실 | 근거 |
| --- | --- | --- |
| TRD-F01 | 복원된 트리에 `legacySettings`만 있고 현재 탭 목록에는 `settings`가 있으면, 호스트를 구성할 수 있어도 `settings` 선택과 그 scope의 push가 `missingScope`로 거절된다. | [호스트](../Sources/InnoRouterSwiftUI/RouterTabHost.swift), [scope](../Sources/InnoRouterSwiftUI/RouterScope.swift), [Reducer](../Sources/InnoRouterCore/RouterReducer.swift); 이번 대화의 macOS `@Router` 재현 |
| TRD-Q01 | 해당 회귀 테스트는 orphan branch 보존과 첫 화면 appearance를 확인하며 변경된 탭의 선택·이동·재저장을 확인하지 않는다. | [RouterTabHostTests](../Tests/InnoRouterTests/RouterTabHostTests.swift)의 `staleRestoredBranchesDoNotAbort` |
| TRD-D01 | 기능 명세는 구현된 기능 합성·가상 시계·부분 복원·탐색 기록을 미구현으로 설명한다. API 예산 문서와 실제 TSV도 다르다. | [추가 기능 명세](6.0.0-next-capabilities-spec.ko.md), [API 문서](v6-public-api-boundary.md), [예산 정본](../Baselines/PublicAPI/symbol-budgets.tsv) |
| TRD-D02 | 문서 검사가 승인 상태 `Draft`와 특정 6.0.0 문구를 고정해 요구한다. 실제 구현·발행 상태와 문서 승인 상태를 별도로 검증하지 않는다. | [check-docs-consistency.sh](../scripts/check-docs-consistency.sh) |

기준 소스에서 로컬 `swift test --jobs 2 --no-parallel`은 638 tests / 80 suites가 통과했고 의도된 known issue 1건이 있었다. 동일 SHA의 원격 CI 7개도 성공했다. 이는 수정 전 기준선이며 이번 계획의 완료 증거가 아니다.

임시 재현 파일은 `/tmp/innorouter-review-20260918-tab-host.swift`와 같은 이름의 `.log`에 있다. 임시 파일의 존속에 의존하지 않고 T01에서 영구 회귀 테스트로 옮긴다. 핵심 결과는 다음과 같다.

```text
macro-tab-id=settings
missing-canonical-tab=true
select-settings=rejected(...missingScope(settings, parent: /))
push-settings-detail=rejected(...missingScope(settings, parent: /))
canonical-selection=legacySettings
revision=0
```

### 사용자에게 필요한 결과

- TRD-US-001: 앱 업데이트로 탭이 추가·제거·변경돼도 복원 뒤 보이는 탭에서 정상적으로 이동하고 돌아올 수 있다.
- TRD-US-002: 유지관리자는 현재 구현·배포 상태와 문서 승인 상태를 구분하고, 일치하는 문서·검사 기준으로 다음 패치를 준비할 수 있다.

## 2. 범위와 제약

포함: macro-first 탭 복원, 그 경계의 상태·화면 일치, 직접·자동·부분 복원 진입점, 정책 거절·취소·stale 처리, 관련 회귀·consumer 검증, 현재 문서와 검사 스크립트 정리, 후속 패치 준비.

제외: 기능 추가, 전체 Store/Reducer 재설계, 새 mutable authority, 임의의 탭 이름 매핑, 저장소 전체 문서 재작성, 다른 Inno 라이브러리·공유 스킬 수정, OS·Swift 하한 변경, 현재 요청에서의 구현·발행.

- TRD-NFR-001: `RouterStore`만 상태를 변경한다. 수락한 전이는 상태를 한 번 대입하고 revision을 한 번 증가시킨다. 거절·취소·stale 결과는 둘 다 바꾸지 않는다.
- TRD-NFR-002: `RouterPlan`과 일반 `.apply`는 정확한 목표 상태라는 기존 의미를 유지한다. 모든 plan을 숨겨진 규칙으로 바꾸는 전역 보정을 넣지 않는다.
- TRD-NFR-003: Swift 6.3+, 기존 플랫폼 하한, 세 공개 product와 공개 API를 우선 유지한다. 새 API가 꼭 필요하면 호환성과 릴리스 종류를 재평가한 뒤 설계에 기록한다.
- TRD-NFR-004: 무관한 branch·window·immersive 상태와 route payload를 보존한다. 진단에 payload를 추가하지 않는다.
- TRD-NFR-005: 테스트는 명시적 이벤트·barrier와 종료 기한을 사용한다. 임의 sleep·반복 yield만으로 실행 순서를 입증하지 않는다.

## 3. 동작 계약과 설계 방향

아래 동작은 구현할 권장안이다. 현재 구현의 보장이나 문서 승인 기록으로 해석하지 않는다.

| 요구사항 | 권장 동작 |
| --- | --- |
| TRD-FR-001 | 현재 탭과 같은 ID의 branch는 path·presentation·badge를 보존하고, 새 탭의 누락 branch는 빈 stack으로 준비한다. 이름 변경은 기본적으로 “기존 ID와 새 ID가 다름”으로 취급하며 옛 기록을 새 탭으로 추측 이전하지 않는다. |
| TRD-FR-002 | 보정 후 selection은 현재 탭 목록 안에 있어야 한다. 기존 selection이 현재 탭이면 유지하고, 아니면 catalog의 첫 탭을 선택한다. native 화면, state reader, 기본 딥링크 목적지가 같은 탭을 가리킨다. |
| TRD-FR-003 | 기본 패치에서는 orphan branch·badge를 임의 삭제하지 않는 보존안을 우선한다. 호스트의 표시·기본 선택·기본 딥링크 대상에서 제외한다. 기록 이전·정리는 앱의 명시적 schema migration으로 수행한다. 재저장·재복원 결과가 반복해서 변하지 않아야 한다. |
| TRD-FR-004 | 정상 정책을 통과한 완성된 복원 후보만 commit한다. 거절·취소·stale이면 직전 정상 상태를 보존하고 결과를 호출자에게 전달한다. 성공한 것처럼 다른 탭만 표시하는 UI fallback으로 끝내지 않는다. |
| TRD-FR-005 | macro-generated catalog와 명시적 manual catalog를 구분한다. manual catalog를 기본 `R.routerTabs`로 덮지 않으며 기존 throwing 검증 계약을 유지한다. root stack·split·scene 구조를 tabs로 자동 변환하지 않는다. |
| TRD-FR-006 | 정본 문서는 승인 상태, 구현 상태, 배포 상태, 증거 기준 SHA·일자를 별도 기록한다. 기존 요구사항 ID·과거 실패·발행 증거를 보존한다. |
| TRD-FR-007 | 문서 검사는 특정 `Draft`나 과거 발행 전 문구의 존재가 아니라 실제 정합성을 검사한다. API 숫자는 TSV와 일치하게 생성 또는 검증하며, 잘못된 상태·숫자 fixture는 실패해야 한다. |

### 비교할 구현안

| 안 | 장점 | 한계 / 판단 |
| --- | --- | --- |
| A. 불일치 snapshot 전체 거절 또는 전체 초기화 | 경계가 단순하고 명시적 migration과 연결하기 쉬움 | 정상 sibling 기록까지 잃을 수 있어 기본 해결안으로 선택하지 않음. 복구 불가능한 구조의 기존 recovery 경로로 유지 |
| B. 복원 후보 준비 단계에서 catalog와 정합화 | 정상 기록 보존, 정책이 완성된 후보를 검토하고 한 번 commit 가능 | catalog의 적용 범위와 직접·자동·부분 복원 연결을 먼저 확정해야 함. 권장안 |
| C. View에서 보정하거나 commit 후 별도 repair 요청 | 렌더링 위치에서 catalog를 알 수 있음 | 중간 불일치 상태, 추가 revision, 정책 재실행·경쟁 위험. `body`/initializer의 상태 변경과 자동 두 번째 commit은 채택하지 않음 |

T02에서 B의 적용 경계를 작은 시제품으로 확정한다. 우선 조사할 위치는 `RouterStore+Snapshot`, `RouterStateRestoration`, `RouterPartialRestoration`의 후보 준비 경계와 `RouterTabHost`의 catalog 소비 경계다. 보정은 순수 value 변환으로 만들고, 정합화된 값을 명시적인 `RouterPlan`으로 정상 실행한다. generic codec이나 순수 `RouterReducer`에 SwiftUI catalog 의존성을 넣지 않는다.

아직 확정하지 않은 기술 판단은 **host가 사용하는 catalog를 복원 경계에 정확히 전달하는 방법**이다. `R: RouterTabRoute`라는 사실만으로 모든 root·scene·manual catalog를 같은 탭 구성으로 간주할 수 없다. 구현 담당자는 T02에서 기존 API만으로 가능한 경계를 입증하고 파일 단위 설계를 갱신한다. 공개 계약 변경이나 추가 상태 권한이 필요하면 이를 숨긴 채 T03으로 진행하지 않는다.

현재 앱이 불일치 상태를 `initialState` 또는 일반 `.apply`로 직접 주입하는 경우도 T02에서 분류한다. 그 경로를 복원 보정으로 위장하지 않는다. 기존 명시적 migration·recovery 사용법 또는 검증된 host 연결 경계를 문서화하고, 수정 범위 밖 입력까지 자동 복구한다고 주장하지 않는다.

## 4. 순차 작업

| 작업 | 내용 / 주요 대상 | 완료 조건 | 선행 |
| --- | --- | --- | --- |
| TRD-T01 | 현재 SHA·작업 트리·도구체인 고정. `RouterTabHostTests`와 복원 테스트에 실제 codec/driver 기반 반례, 정상 대조군 추가 | 추가·삭제·이름 변경 후 선택·push가 현재 코드에서 의도한 assertion으로 실패하고 정상 catalog는 통과. compiler/setup 오류는 반례에서 제외 | 없음 |
| TRD-T02 | 위 설계안 비교 확정. catalog 소유·적용 범위, 초기 상태·직접/자동/부분 복원·manual catalog 경계와 파일 변경안 작성 | B가 NFR-001~004를 만족함을 시제품으로 확인. 공개 API·상태 권한 영향, orphan 보존, 복구 불가능 입력 결과를 기록 | T01 |
| TRD-T03 | 선택한 경계에 순수 정합화와 복원 연결 구현. UI만의 selection fallback에 의존하는 경로 정리 | 수정 전 반례 통과, 정상 기록 보존, 단일 commit, 반복 복원 안정성, 정책·취소·stale 계약 통과 | T02 |
| TRD-T04 | macOS mounted host 및 iPhone/iPad Simulator에서 복원→탭 선택→push/back→딥링크→재저장→재실행 검증. `ConsumerSmoke`에 공용 API 소비 회귀 추가 | state·화면·저장 바이트를 각각 검사. 실기기 결과로 과장하지 않음 | T03 |
| TRD-T05 | 정본 기능·API 문서와 docs-consistency 검사 정리. 배포 후 문서 lifecycle·API 숫자 오류 fixture 추가 | Draft 승인 상태를 임의 승격하지 않고 구현·발행 사실을 갱신. 정상 fixture 통과 / 불일치 fixture 실패 | T02; 최종 내용은 T04 뒤 확정 |
| TRD-T06 | 최종 후보 고정, 관련 경로 재검토, 전체 로컬·필수 플랫폼 gate와 외부 consumer 실행 | 모든 AC에 해당 후보의 증거 연결. 새 회귀가 없고 미실행 검증은 별도 표시 | T04, T05 |
| TRD-T07 | 발행 단계에서 버전·변경 이력 정리, 정확한 commit의 원격 CI·tag·Release·DocC·tag consumer 확인 | 실제 발행 결과와 SHA 일치 증거까지 있어야 배포 완료 | T06 및 commit/push/발행 작업 범위 확정 |

변경 파일은 필요한 범위로 한정한다. 테스트 구조는 “검토 차수”보다 탭 복원·catalog·정책 계약을 드러내는 이름을 사용한다. runtime/회귀 변경, 문서/검사 변경, 릴리스 메타데이터는 검토 가능한 별도 변경 단위로 나눈다.

### T05 문서 범위

- `Docs/v6-functional-strategy.md`, `Docs/functional-expansion-spec.md`: 문서 승인 상태와 현재 구현·배포 사실 분리.
- `Docs/6.0.0-next-capabilities-spec.ko.md`, 연결된 기술 계획: “아직 구현되지 않음”을 현재 소스·테스트·발행 증거와 대조해 정정. 전체 AC를 증거 없이 일괄 완료하지 않음.
- `Docs/v6-public-api-boundary.md`: TSV를 정본으로 숫자 일치 및 갱신 방법 명시.
- `scripts/check-docs-consistency.sh`와 관련 script 테스트: 상태 전환 허용, 실제 불일치 감지, 차기 패치 버전과의 호환성 검증.
- `README.md`, `README.ko.md`, 필요한 DocC·예제: 탭 ID 변경과 명시적 migration/recovery 사용법을 같은 메시지로 설명.
- `RELEASING.md`: 기본 테스트 명령을 `--jobs 2 --no-parallel` 계약과 정렬.
- `CHANGELOG.md`: `Unreleased`에 실제 수정 후 동작과 제한을 기록. 기존 6.0.0 변경 이력은 사실 정정 외에는 유지.

`Docs/6.0.0-release-checklist.md` 상단에는 이미 발행 완료 증거가 있다. 이를 미배포로 되돌리지 않는다. 그 문서의 “태그가 존재한 후 exact consumer를 실행한다”는 선행 조건 자체는 타당하므로 삭제 대상이 아니다. 과거 체크리스트와 다음 배포의 현재 상태를 구분하고, 검사에서 그 특정 문구를 현재 상태의 대용으로 사용하지 않도록 한다.

## 5. 인수 기준과 추적

| 인수 기준 | 요구사항 | 통과 조건 | 작업 / 증거 |
| --- | --- | --- | --- |
| TRD-AC-001 | FR-001, FR-003 | 동일 catalog와 탭 순서·번역 변경 시 기존 branch의 path·presentation·badge 보존 | T01, T03 / 정상 대조군 |
| TRD-AC-002 | FR-001, FR-002 | 탭 추가·이름 변경 후 새 탭 선택 및 push/back 성공, `missingScope` 없음 | T01, T03, T04 / runtime 및 mounted assertion |
| TRD-AC-003 | FR-002, FR-003 | 선택된 탭 삭제 시 native selection·state reader·기본 딥링크 대상이 catalog 첫 탭으로 일치 | T03, T04 / 삭제·링크 시나리오 |
| TRD-AC-004 | FR-001, FR-003 | orphan 보존과 정상 sibling 기록 보존, 저장→decode→다시 복원 결과가 동일 | T03, T04 / codec·file round trip |
| TRD-AC-005 | FR-004 | 정책이 최종 후보를 관찰. 수락 시 1 commit/1 revision, 거절·취소·stale 시 이전 상태·revision 유지 | T03 / 정책·지연 복원 경계 테스트 |
| TRD-AC-006 | FR-004, FR-005 | 직접·자동·부분 복원에서 같은 보정 계약. 두 번째 repair 전이나 Task 타이밍에 기대어 성공하지 않음 | T03, T04 / 각 진입점 독립 실행 |
| TRD-AC-007 | FR-005 | manual catalog·일반 `.apply`·root stack·split·scene 정상 계약 유지. 복구 불가능 입력은 기존 recovery 또는 명시한 typed 실패로 처리 | T02, T03 / API·정상/오류 대조군 |
| TRD-AC-008 | FR-006 | 구현 여부·발행 여부·승인 여부·기준 SHA가 서로 모순되지 않음. 과거 기록·요구사항 ID 보존 | T05 / 문서 대조·링크 검사 |
| TRD-AC-009 | FR-007 | 실제 TSV 일치, 숫자 drift는 실패. 유효한 승인/구현/배포 상태 조합은 통과하며 오래된 고정 문구만으로 통과하지 않음 | T05 / script 정상·오류 fixtures |
| TRD-AC-010 | FR-001~007, NFR-001~005 | 최종 후보의 공개 API·전체 suite·consumer·문서·lint·지원 플랫폼 gate 통과 | T06 / 후보 manifest·명령·exit·로그 |
| TRD-AC-011 | FR-006, FR-007 | 발행 시 정확한 tag revision을 소비자가 resolve하고 runtime 버전·Release·버전별 DocC·latest가 일치 | T07 / 원격 SHA·resolved revision·실제 URL |

위 표의 `FR-*`, `NFR-*`는 같은 문서의 `TRD-` 접두사를 생략한 표기다. 새 결과는 별도 실행 기록에 AC, 테스트명, assertion, 수정 전·후 결과, 후보 SHA/patch hash, 도구체인·플랫폼을 연결한다.

반례 검토: “화면은 홈이지만 canonical selection은 제거된 탭”, “새 탭은 보이지만 이동 불가”, “복원 뒤 두 번째 repair가 우연히 성공”, “같은 이름으로 추측 매핑해 다른 기록 노출”, “문서를 전부 Approved로 바꿔 검사만 통과”하는 구현은 위 AC를 만족할 수 없어야 한다. T02와 T06에서 이를 명시적으로 재확인한다.

## 6. 검증과 발행 경계

수정 단위마다 focused 회귀를 실행하고, 최종 후보에서는 `./scripts/principle-gates.sh --platforms=all`을 기준으로 전체 package·macro·DocC·API·문서 예제·lint·consumer·플랫폼 compile/interface 증거를 모은다. 이 script에 포함된 검사는 불필요하게 중복 실행하지 않는다. 상태·비동기 경계 변경은 관련 ASan/TSan을 추가하고 coverage·성능은 기존 gate를 유지한다.

native 검증은 T04의 macOS·iPhone/iPad 시나리오와 저장소의 필수 scene/Inspector 검증을 구분해 기록한다. 지원 플랫폼의 원격 runtime test는 compile 성공과 별개로 확인한다. 실기기·VoiceOver 사용성은 이번 계획에서 새 선행 조건으로 추가하지 않는다.

공개 API 변경 없이 호환성 수정으로 끝나는 경우 후속 6.0.x 패치를 준비한다. 버전은 그 시점의 최신 release를 다시 확인해 정한다. additive API가 필요하면 minor, breaking 변경이 필요하면 다음 major 원칙을 적용하며 패치로 위장하지 않는다.

태그 전에는 정확한 후보의 로컬 consumer와 원격 CI를 확인하고, 태그 후에는 `./scripts/external-consumer-smoke.sh <확정버전>`과 resolved revision을 확인한다. 기존 tag는 이동하지 않는다. Release·versioned DocC·latest 배포가 실패하면 수정 완료와 발행 실패를 별도로 보고하고 배포 완료라고 기록하지 않는다.

## 7. 실행 결과

TRD-T01~T06은 런타임 커밋 `102c03ca`와 문서·gate 후속 커밋으로 수행했다.
요구사항별 구현·검증 판정은
[실행 및 명세 대조 기록](review-evidence/2026-09-18-tab-restoration-and-docs.ko.md)에
연결한다. 로컬 검증은 Xcode 26.6 / Swift 6.3.3에서 수행했으며, 다음 결과를
현재 working-tree 후보의 증거로 사용한다.

- 전체 package 644 tests / 80 suites 통과. 기존 의도된 known issue 1건 외 새 issue는 없다.
- `principle-gates.sh --platforms=all` 통과: DocC, 공개 API, 문서 예제, lint, 외부 consumer, iOS/iPadOS·Mac Catalyst·macOS·tvOS·watchOS·visionOS compile/interface.
- iPhone 27.0과 iPad 26.5 Simulator에서 platform runtime 12 tests가 각각 실패·skip 없이 통과했고, 새 tab 복원 및 `UIHostingController` mount 테스트가 실제 실행됐다.
- TSan 331 tests / 37 suites와 ASan 295 tests / 40 suites 통과. TSan에는 기존 의도된 known issue 1건이 포함된다.
- gated coverage 89.58%, comprehensive coverage 84.50%, release 성능 7개 예산과 5.2.1→현재 migration smoke 통과.

현재 단계는 **로컬 검증 완료**다. TRD-T07의 tag·GitHub Release·versioned DocC
발행은 수행하지 않았다. commit/push 뒤 정확한 원격 SHA의 필수 CI와 최신 release를
다시 확인해 배포 준비 여부를 판정한다.
