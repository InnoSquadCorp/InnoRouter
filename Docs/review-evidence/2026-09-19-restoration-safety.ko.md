# 명시적 탭 복원 안전성 수정·재검토 기록

## 기준과 범위

- 시작 HEAD: `9ef59d64de1467a3d426c89de7b34a6625af96b5`, clean main.
- 요청: 추가 검토에서 재현한 결함을 수정하고 변경 후 다시 검토.
- 기준 계획: [복원 경계 재설계 계획](../2026-09-18-restoration-boundary-remediation-plan.ko.md), Draft 0.3. 문서 승인과 실행 요청은 구분한다.
- 이전 검토의 재현: `/tmp/innorouter-current-review-20260919.7QskgA/`.
- 이번 로그·xcresult: `/tmp/innorouter-fix-verification.uVvpSy/`.
- 코드 후보 manifest: `candidate-files.sha256`, SHA-256 `cbda6f9d7d2d501e49a30585e16230973873af8508bdfe2a9513ee5c4671212f`.
- 현재 상태: 제품 수정·전체 로컬 gate·native/sanitizer 통과. 이 기록은 commit 전 후보의 검증이며 원격 CI 결과는 push 후 별도로 확인한다.

## 수정 전 실패와 구현

`RouterTabRestorationSafetyTests`를 먼저 추가하고 기존 코드에서 focused 실행했다.
3 tests / 7 issues로 예상한 실패를 확인했다. 로그는 `/tmp/innorouter-safety-red-20260919.log`다.
공개 보정의 중복 ID 크래시는 이전 동일 HEAD의 격리 프로세스에서 SIGTRAP을 확인했으며,
수정 전 전체 테스트 프로세스를 다시 강제 종료하는 대신 같은 입력을 permanent typed-error
assertion으로 옮겨 수정 후 실행했다.

| 발견 | 수정 | 검증 |
| --- | --- | --- |
| S1: tab-aware 직접 복원 두 경로가 decode 중 새 commit을 덮음 | public 진입점에서 revision을 캡처해 helper/perform에 전달. 기존 generic exact 의미 유지 | `newerNavigationDuringDecode`: direct/recovery/partial/explicit revision은 stale 거절, legacy exact는 기존 적용 의미 유지 |
| S2: public `reconciling`의 중복 branch 사전 생성에서 trap | `RouterState.validate()`를 사전 생성 전에 실행 | `invalidMutableState`: duplicateScope typed 오류 |
| S3: 현재 탭의 container node를 적용하고 push에서 뒤늦게 실패 | 현재 scope에 대해 stack 형태를 먼저 검증, 새 host도 같은 검사 재사용 | `nonStackCurrentBranch`: codec-valid 입력도 commit 전 expectedStack 거절, revision/state 보존 |
| S4: 추가 확인한 orphan selection의 화면/기본 목적지 불일치 | 새 orphan 허용 host도 selection이 현재 catalog에 있는지 검증 | `orphanSelectionAndSubtree`: orphan 선택 거절, 보정 뒤 허용, orphan의 container payload는 보존 |
| G1: 부정·미래 발행 문구를 배포 완료로 판정 | 구현/발행 상태를 정확한 필드 값으로 분리. Published에는 SemVer/전체 SHA/일자 요구 | 실제 checker를 호출하는 7개 unittest와 subtests. 부정/미래/한글 부정/중복/누락/모순/잘못된 버전·날짜 거절 |
| G2: 빈 탭 추가·순서·selection 보정의 설명 누락 | `RouterTabRestorationChange`, `report.topologyChanges` 추가. 기존 initializer 및 과거 JSON decode 유지 | `structuralReport`, `rejectedCandidateReport`: 후보 설명과 실제 적용 여부 구분, old report round trip |
| G3: 외부/native/교체 중 worker 검증 공백 | 외부 macro 소비자 추가. 운영 onOpenURL의 submission 및 host 기본 plan을 재사용하는 native 테스트. 늦은 decoder 종료 barrier 추가 | `explicitTopologyConsumer`, `mountedRestorationAndURLs`, `replacementDriverWhileDecoding` |

새 보고서가 늘린 공개 심볼은 **8개**, 기존 심볼 제거는 **0개**다. 변경 항목은 구조 변경
enum/3개 case, report property/추가 initializer와 명시적 Codable 구현이다. 예산은
InnoRouter 1172→1180으로 그 변경에 한해 조정했다. Inspector 207, Testing 252는 유지한다.
snapshot JSON schema와 6.0의 generic restore·manual strict initializer는 바꾸지 않았다.

## 인수 기준 재대조

| 기존 기준 | 새 증거 | 판정 |
| --- | --- | --- |
| RBR-AC-001~005 | 기존 boundary/topology suite + full suite, orphan/stack 대조군 | 기존 의미 유지 |
| RBR-AC-006 | 보정된 후보 validator, `topologyChanges`, 거절된 후보 보고, old JSON fixture | 확인 |
| RBR-AC-007 | decode 진입/해제 barrier 사이 새 commit, direct/recovery 취소, partial/explicit revision 정상 대조 | 확인 |
| RBR-AC-008 | invalid current node 및 orphan selection typed 실패, strict와 opt-in host의 외부 소비 대조 | 확인 |
| RBR-AC-009 | 첫 decode를 정지한 상태에서 stop→새 driver 복원→옛 decode 해제. 두 worker 종료까지 기다린 뒤 state/revision 확인 | 확인 |
| RBR-AC-010 | 외부 `@Router`/TestStore/host 소비, 실제 mounted scope reader·탭/상세 URL submission, sanitizer의 새 suite 실행 | 자동화 범위 확인 |
| RBR-AC-011 | 구조화된 lifecycle fields, candidate version/TSV 검사, 미출시 API README 표시 | 확인 |
| RBR-AC-012 | 최종 전체 로컬 gate 통과. 동일 후보 원격 CI는 push 뒤 확인 | 로컬 완료 / 원격 별도 |
| RBR-AC-013 | 실제 6.1 tag·Release·DocC·exact consumer | 발행하지 않음 |

## 실행 결과

| 검증 | 결과 |
| --- | --- |
| `swift test --jobs 2 --no-parallel` | 665 tests / 84 suites 통과. 기존 known issue 1건 |
| 외부 consumer | 8 tests / 2 suites 통과. 신규 macro topology/strict/opt-in/TestStore/round trip 실행 |
| metadata checker fixtures | 7 unittest groups 및 하위 조합 통과 |
| TSan | 375 tests / 44 suites 통과. 기존 known issue 1건 |
| ASan | 363 tests / 48 suites 통과 |
| iPhone 17 Pro / iOS 26.5 Simulator | 11 tests(파라미터 포함 12 실행) 통과, 실패·skip 0. 새 mounted test 0.105초 |
| iPad Pro 13-inch M4 / iOS 26.5 Simulator | 11 tests(파라미터 포함 12 실행) 통과, 실패·skip 0 |
| `principle-gates.sh --platforms=all` | exit 0. 전체 suite·DocC·API·문서·lint·consumer·iOS/iPadOS·Mac Catalyst·macOS·tvOS·watchOS·visionOS build/interface 통과 |

전체 테스트 로그는 `/tmp/innorouter-full-fixed-20260919.log`다. API baseline 재생성 직후
새 public symbol 예산 초과를 확인하고 실제 +8 항목을 검토해 예산을 맞췄다. baseline을
쓰는 중 별도로 실행한 docs 검사는 임시 빈 baseline을 보았으므로 유효한 결과로 세지
않는다. 최종 principle gate에서 안정된 baseline·문서 후보를 다시 검사한다.

## 수정 후 재검토와 남은 경계

- 변경된 public 입력, direct/recovery/partial/driver 실행 순서, stale/cancellation,
  구조 보고의 Codable 호환성, strict/opt-in host와 URL submission을 다시 읽고 반례와
  정상 대조군을 확인했다. 이번 수정 범위에서 추가 차단 런타임 결함은 확인하지 못했다.
- native 테스트는 window에 host를 mount한 뒤 scoped reader와 실제 destination의
  appearance/path 변경을 관찰한다. 탭/상세 URL은 **운영 onOpenURL이 호출하는 동일
  submission 함수**에 전달하며 별도 선택 로직을 복제하지 않는다.
- OS가 외부 URL을 앱에 전달하는 과정, 사람이 누르는 native back/gesture, 프로세스
  종료·재실행의 수동 QA는 별개다. 테스트의 system-origin pop 및 새 Store 재복원을
  물리 입력이나 프로세스 재실행 성공으로 표현하지 않는다. RBR-QA-001은 그 범위가 남는다.
- macOS native root는 pop 시 onAppear가 다시 호출되지 않을 수 있어, 테스트는 실제
  scoped reader의 onChange도 관찰한다. 이를 제품 실패로 분류하거나 timeout 확대만으로
  숨기지 않았다.
- 이전 presentation ID scope 이동의 "throw 없음=성공" 판정은 이미 정정했다.
  기존 presentationIdentityConflict 계약은 변경하지 않는다.

발행하지 않은 API의 6.1 경계를 README 양 언어와 DocC에 표시했다. 6.1 version/tag/Release
발행은 이번 수정 작업에서 수행하지 않는다.

## 원격 coverage에서 확인한 테스트 동기화 후속 수정

제품 수정은 `345903937d3d3d4388568b03c3a9ff4d1d7bed34`로 push했다. 동일 SHA의
coverage run `35418080145`에서 기존 `historyStopReleasesActivePolicyLane`이
"Stopped history left the router policy lane busy"로 실패했다. 커버리지 비율 실패가
아니라, `stop()` 뒤 `Task.yield()` 한 번을 취소 완료로 간주한 테스트의 실행 순서 문제다.
Store는 취소를 요청한 뒤 비동기 policy race를 종료하고 `finishExecution`에서 슬롯을
해제한다. 같은 파일의 restoration 테스트는 이미 이 비동기 계약을 명시하고 있었다.

- stop/reset/caller-cancel 세 테스트에서 실제 `activeTransitionID == nil`을 제한 시간
  안에 확인한 뒤 다음 이동을 요청한다. 고정 yield 횟수와 caller 반환 시점 추측을 제거했다.
- policy gate 진입도 공용 bounded event helper로 대기하고, 오류 경로의 gate/task/history
  정리를 defer로 보장한다. policy gate를 해제하기 **전에** 다음 이동 성공을 확인하므로
  테스트 정리가 취소 결함을 숨기지 않는다.
- "busy만 아니면 됨" 대신 applied와 최종 경로까지 단언한다. 제품 코드는 추가 변경하지 않았다.
- `swift test --enable-code-coverage --jobs 2 --no-parallel`: 665 tests / 84 suites 통과,
  기존 known issue 1건. 로그 `coverage-local.log`.
- 변경한 세 경로를 coverage binary로 5회 독립 실행해 모두 통과했다.
- gated coverage 89.58% (16695/18636), comprehensive 84.89% (19690/23195).
  기존 85% / 83% 기준을 유지했다.
- 후속 후보 manifest: `candidate-files-followup.sha256`, SHA-256
  `432091b89e375c4bdfc549c246b78d331c5eea859891b9d1a917fe8cc8f78393`.

앞선 native/platform/API/sanitizer 증거는 제품 코드가 동일한 `34590393` 후보의 결과다.
후속 변경은 이 테스트 파일과 실행 기록뿐이며, 최종 원격 CI는 후속 commit에서 다시 확인한다.
