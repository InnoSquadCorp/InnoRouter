# 6.1.0 배포 전 복원 안전성·호환성 후속 개선 계획

| 항목 | 내용 |
| --- | --- |
| 문서 상태 | Draft |
| 작성일 / 문서 버전 | 2026-09-21 / 0.1 |
| 작성자 / 결정 책임자 | Codex / 프로젝트 유지관리자(사용자) |
| 검토자 / 승인자 / 승인일 | 미기록 / 미기록 / 미기록 |
| 기준 소스 | `b82b2a81ec241ed21e620741ed5aa8892800f189` |
| 구현 상태 | 부분 구현 — T701~T703 로컬 검증 완료, T704~T706 진행 중 |
| 배포 상태 | 미배포 |
| 설계 깊이 | standard — 저장 파일 손실, 공개 오류 호환성, SwiftUI 생명주기, CI 운영 설정을 함께 다룸 |
| 요청 범위 | 직전 재검토의 두 결함과 추가 개선점을 실행 가능한 후속 계획으로 정리 |

목표는 복원 실패 시 기존 파일을 보존하고 6.0.0 오류 계약을 회복한 뒤, 누락된 검증과
CI 운영 보호를 보강하여 6.1.0 발행 후보를 다시 판단하는 것이다. 새 라우팅 기능은 추가하지 않는다.
이번 산출물은 계획이며 제품 코드, GitHub 설정, 버전, 태그, Release는 변경하지 않는다.

선행 계약은 [입력 한도·자동 부분 복원·명시 ID·CI 계획](2026-09-21-restoration-and-ci-improvement-plan.ko.md)의
RXP-FR/AC와 공통 6.0.0 호환성 제약이다. 선행 완료 기록을 지우거나 재작성하지 않고 이 후속 계획으로 추적한다.

## 1. 확인된 사실과 판단 경계

| 구분 | 근거 / 현재 판단 |
| --- | --- |
| F1 / P1 | `RouterStateRestorationModifier.swift`는 비활성 scenePhase에서 무조건 공개 `save()`를 호출한다. 정상 codec으로 만든 1,300바이트 파일을 512바이트 storage 한도로 열면 복원 실패 후 같은 저장 호출로 100바이트 초기 상태가 기록된다. revision은 0, status는 failed→inactive. 파일과 공개 API 재현이며 실제 scenePhase UI 재현은 아직 없음 |
| F2 / P2 | `RouterSnapshot.swift`의 migration catch가 앱이 던진 `RouterSnapshotError`도 그대로 전달한다. 공개 6.0.0은 모든 transform 오류를 `migrationFailed`로 감쌌다. 제한 없는 기존 initializer에서도 `.use` 복구 분기가 달라짐을 재현 |
| 자동 검증 | 직전 검토에서 기준 SHA의 원격 workflow 7개와 로컬 집중 테스트 66개 통과. 결함 두 건은 별도 재현에서 확인했으며, 통과 개수가 해당 경계의 안전성을 증명하지 않음 |
| CI 운영 | 직전 GitHub 조회에서 main에 deletion/non_fast_forward 규칙만 확인. required status checks 없음. 실제 적용 전 ruleset·bypass·권한과 check context를 다시 읽음 |
| CI 성능 | 기존 핵심 step 기준선 중앙값 712초, cache warm 중앙값 761초. cache는 제거됨. 최종 SHA 708초는 단일 표본이므로 반복 성과로 해석하지 않음 |
| 발행 | runtime 6.0.0, 변경 내역 Unreleased. 직전 확인의 최신 Release는 6.0.0. 실제 발행 시 원격 태그·Release·문서 상태를 다시 확인 |

실행 착수 시 HEAD·dirty 상태를 다시 확인한다. 기준 SHA 이후 다른 변경이 있으면 해당 diff와
두 재현을 먼저 대조한다. Store 단일 변경 권한, public product 3개, Swift/OS 하한,
snapshot schema, 기존 명시적 저장/삭제 API 의미를 유지한다.

## 2. 작업 순서와 인수 기준

| 순서 / 작업 | 연결 요구사항 | 완료 조건 |
| --- | --- | --- |
| RRR-T701 — 자동 생명주기 저장 보호 | RXP-203, 302~304 / RRR-AC-01~03 | F1 재현이 수정 전 실패·수정 후 통과. 실패/대기/거절/지연 후보는 자동으로 파일을 덮지 않고 정상 복원·새 navigation 저장은 유지 |
| RRR-T702 — migration 오류 호환성 | RXP-202 및 공통 호환성 / RRR-AC-04 | 기존 initializer와 제한형 initializer의 transform 오류·`.use` 결과가 6.0.0 계약을 유지. 라이브러리의 실제 한도 초과는 새 typed 오류로 구별 |
| RRR-T703 — 실제 파일·host 및 검증 공백 보강 | RXP-201, 301~304, 402 / RRR-AC-05 | 실제 파일 재실행, mounted scenePhase, 부분 복원 경계와 잘못된 ID 진단을 직접 assertion으로 검증 |
| RRR-T704 — 필수 CI 검사 강제 | RXP-503 / RRR-AC-06 | 모든 필수 job과 실제 required context의 대응 확인. 기존 규칙 보존. 설정 적용 전후 증거와 실패/누락 검사 차단 확인 |
| RRR-T705 — CI 세부 계측·반복 비교 | RXP-501~504 / RRR-AC-07 | 동일 제품 소스·환경의 원시 측정값과 반복 중앙값 확보. 실측 이득 없는 변경은 제외. 목표 미달도 결과로 기록 |
| RRR-T706 — 통합 검증·배포 재판정 | 전체 / RRR-AC-08 | 관련 로컬 gate, 정확한 최종 SHA의 원격 CI, 변경 재검토 및 릴리스 준비 상태를 각각 보고 |

표의 RXP 약칭은 기존 `RXP-FR-*`와 대응 `RXP-AC-*`다. 각 단계의 필수 회귀가 통과한 뒤 다음 단계로 이동한다.
T705는 측정·보고까지 수행하되 20% 시간 단축 자체를 배포 필수 조건으로 삼지 않는다.

## 3. T701 — 자동 저장과 명시적 저장의 계약

### 구현 대상과 선택

- `Sources/InnoRouterSwiftUI/RouterStateRestoration.swift`: 저장 가능 근거와 활성화 generation/attachment 소유권 관리.
- `RouterStateRestorationPersistence.swift`: 자동 flush 전용 내부 진입점과 기존 durability/save generation/epoch 검사 연결.
- `RouterStateRestorationModifier.swift`: scenePhase에서 공개 무조건 save 대신 자동 flush 진입점을 호출.
- `RouterRestorationDriverTypes.swift`: 필요한 경우에만 내부 상태 추가. 새 공개 API는 기본적으로 필요하지 않다.

공개 `save()`는 앱의 명시적 저장 의사를 계속 존중한다. 자동 flush는 표시용 `status`가 아니라
초기 복원의 실제 결과, 독립적인 최신 committed revision, 현재 소유권을 근거로 허용한다.
`status`는 save/remove 등에 의해 바뀌며, `initialRestorePhase == completed`도 rejected/deferred를
포함할 수 있으므로 둘 중 하나만 검사해서는 안 된다.

| 상황 | 자동 flush 규칙 | 직접 확인할 결과 |
| --- | --- | --- |
| 최초 load/decode/validator/policy 대기, 별도 commit 없음 | 보류 또는 no-op | 초기 상태로 원본을 덮지 않음; revision 변화 0 |
| load/한도/decode/migration 실패, 별도 commit 없음 | no-op | 파일 바이트와 실패 status 보존; 재시도 가능 |
| rejected/cancelled/stale 후보, 별도 commit 없음 | no-op | 해당 후보 또는 초기 상태 저장 없음 |
| deferred 후보, 별도 commit 없음 | terminal 수락 전 저장 금지 | report 존재를 성공 근거로 쓰지 않음 |
| noSnapshot 또는 terminal applied/unchanged | 현재 수락 상태 저장 허용 | 정상 시작·부분 정상화 저장·재실행 유지 |
| 실패/대기/거절 사이의 독립적인 새 navigation commit | 해당 최신 상태 저장 허용 | 오래된 복원 후보가 아닌 새 state를 저장; revision 추가 증가 없음 |
| stop/마지막 detach/driver 교체/삭제 이후 늦은 flush | 이전 소유권 작업 무효화 | 원본·새 generation·삭제 결과를 뒤늦게 덮지 않음 |
| 앱의 명시적 save/remove | 기존 계약 유지 | 복원 실패 후 명시 저장 재시도와 삭제 가능 |

자동 저장 예약 시 generation/attachment와 storage epoch를 잡고, suspension 뒤에도 기존
순서 보장을 유지한다. 삭제 뒤 기존 저장이 파일을 되살리지 않아야 한다. no-op flush는
status 작업을 새로 소유하거나 실패 상태를 지우지 않는다. 공유 driver의 한 host가 detach해도
남은 owner의 정상 작업을 막지 않는다. 자동 쓰기가 실제 시작된 이후의 강제 I/O rollback은 약속하지 않는다.

실패 시 observation이 종료되는 현재 동작을 고려한다. 새 정상 navigation 판정은 observer가
항상 살아 있다고 가정하지 않고 activation 기준 revision과 소유권도 대조한다. 재연결 시
원본을 재시도할지 여부는 기존 stop/detach 정책을 유지하며, 저장 허용 플래그로 덮어쓰지 않는다.

**RRR-AC-01:** 정상 snapshot의 한도 초과·미래 schema·decode 실패 후 active→inactive→background에서
원본 bytes, Store state/revision, 실패 표시가 보존된다. public save 대리 호출만으로 완료 처리하지 않는다.

**RRR-AC-02:** load/decode/validator/policy barrier마다 background 및 취소/stop/마지막 detach/교체를
연결해 늦은 작업의 write/commit/report 갱신을 막는다. 대표 경로는 mounted host에서 검사하고,
나머지 세부 조합은 제어 가능한 barrier로 검사한다. 모든 barrier·Task·host는 실패 시에도 해제한다.

**RRR-AC-03:** noSnapshot, applied, unchanged, deferred→accepted와 독립 navigation은 저장된다.
명시 save/remove, 공유 owner, retry, 삭제 순서의 기존 회귀를 보존한다. 실패 no-op에서는 저장 호출 0회다.

## 4. T702 — 오류의 발생 주체 구분

`Sources/InnoRouterCore/RouterSnapshot.swift`에서 migration transform만 기존 do/catch-all로 감싼다.
반환 payload 한도 검사는 해당 catch 밖에서 수행한다. 오류 case나 snapshot schema를 새로 바꾸지 않는다.

**RRR-AC-04**의 회귀 행렬:

| 조건 | 기대 결과 |
| --- | --- |
| 앱 transform이 일반 Error를 던짐 | `migrationFailed(from:to:message:)` |
| 앱 transform이 RouterSnapshotError를 던짐 | 기존과 동일한 `migrationFailed`; `.use`에서 동일 fallback |
| 라이브러리의 migration 출력 한도 검사 실패 | 실제 payload 한도 typed error; 다음 migration/route decode 호출 0회 |
| 제한 없음 / 충분한 제한 / 정상 migration | 기존 성공 state와 schema 변환 동일 |

`Tests/InnoRouterTests/RouterSnapshotLimitTests.swift`, 기존 snapshot migration 테스트와
`ConsumerSmoke/`의 외부 소비자에서 기존·제한형 initializer를 모두 확인한다. direct/driver가
오류를 다시 분류하지 않는지도 대조한다. 실패 후보의 state/revision/file 변경은 없어야 한다.

## 5. T703 — 실제 저장·생명주기와 남은 검증 공백

**RRR-AC-05**를 다음 묶음으로 추적한다. 기존 테스트가 동일 assertion을 증명하면 재사용하고
파일명이나 테스트 개수만으로 충족 처리하지 않는다.

- `Tests/InnoRouterPlatformTests/RestorationLifetimeTests.swift`: 기존 hosting helper를 이용해
  modifier를 실제 탑재하고 scenePhase를 변경한다. 주입한 environment 전환과 OS가 보낸 실제
  background 이벤트는 구별해 기록한다. 대표 앱에서는 background→종료→재시작 smoke도 확인한다.
- `RouterRestorationDriverPartialTests.swift`와 `TabRestorationExampleTests.swift`: 메모리 storage만
  쓰던 정상화 시나리오를 임시 파일의 `RouterFileSnapshotStorage`로 추가한다. 새 driver가
  제거된 route를 되살리지 않고 topology/명시 ID와 함께 복원되는지 확인한다.
- 부분 복원: keep/remove/replace, 필수 fallback과 presentation/window/immersive의 기존 direct
  테스트를 driver와 대조한다. 신규 commit/마지막 detach/교체/caller 취소, 이전 report가 있는
  상태의 재시도·noSnapshot·실패, deferred 수락/거절과 저장 실패를 보강한다.
- `RouterSnapshotLimitTests.swift`: `Int.max` 상한, chunk 경계 및 읽기 중 파일 증가/축소를
  제어 가능한 조건에서 검증한다. 필요할 때만 내부 reader seam을 두고 공개 테스트 전용 API는 추가하지 않는다.
- `Tests/InnoRouterMacrosTests/RouterCompositionMacroTests.swift`: empty/whitespace/interpolation을
  각각 실패 fixture로 추가한다. 기존 dynamic/escape/effective ID 중복과 runtime rename 테스트는 유지한다.
- 최소 지원 OS는 설치 가능한 runtime부터 확인한다. iOS 18/macOS 15 대표 복원 smoke를 실행할
  수 있으면 기록하고, 환경이 없으면 미실행 사유와 후속 담당을 남긴다. 최신 OS 성공으로 대체하지 않는다.

복원 파일 보존과 오류 호환성의 직접 회귀는 필수다. 사용할 수 없는 최소 OS 환경은 미검증 위험으로
명시하여 최종 판단에 포함하며, 이 계획에서 모든 최저 OS 실행을 완료했다고 가정하지 않는다.

## 6. T704 — CI 필수 검사 운영 설정

**RRR-AC-06:** workflow 파일의 존재, job 성공, GitHub가 요구하는 상태 검사를 각각 확인한다.

1. 현재 main ruleset/protection/bypass 설정과 GitHub App 식별자, 실제 check-run 이름을 읽어
   설정 원본을 보관한다. 현재 권한을 확인하며 새 토큰이나 권한 확대를 임의로 요구하지 않는다.
2. `principle-gates`의 gates/lint/changelog-sync/release-contract, docs-ci의 docc,
   migration/coverage/performance, ASan/TSan, 플랫폼 build/test·Inspector UI를 전수 매핑한다.
   workflow 표시명을 check context로 추정하지 않는다. 경로 필터·조건부 skip·중복 이름을 점검한다.
3. 누락 없이 항상 보고되는 context만 required 목록에 넣는다. 집계 job이 필요하면 같은 workflow의
   실제 결과를 검사하고 skipped/cancelled/failure를 성공으로 포장하지 않는다. 워크플로 간 결과를
   이름만 확인하는 빈 집계 job으로 대체하지 않는다.
4. 기존 삭제/force-push 방지와 bypass 범위를 보존한 최소 ruleset diff를 준비한다. 필수 검사 외의
   리뷰 인원·조직 정책 변경은 포함하지 않는다. 기능 수정의 검증·반영 후 설정을 활성화하고 다시 조회한다.
5. 이후 변경은 필요한 검사가 실행되는 PR 경로로 진행한다. 권한 있는 운영 변경 단계에서
   실패/누락 check가 있는 검증용 PR의 병합 불가 상태를 확인하고 정리한다. 소유자 bypass만으로
   성공/차단을 판단하지 않는다. 확인하지 못하면 설정됨과 강제 검증됨을 분리해 보고한다.

대상은 `.github/workflows/*.yml`, `scripts/test-ci-optimization-contract.py`, `Docs/CI-gates.md`와
GitHub repository ruleset이다. 설정을 코드로 보관할 경우 새 export/diff 문서에 실제 값을 기록한다.
운영 설정 변경은 향후 이 계획의 실행 단계에서 수행하며 지금 적용하지 않는다.

## 7. T705 — 측정부터 다시 하는 CI 개선

**RRR-AC-07:** T703 완료 소스를 고정하고 `scripts/principle-gates.sh` 및 관련 helper의
dependency resolve/compile/test/DocC 구간을 계측한다. 기존 명령에 포함된 암묵적 resolve/compile을
분리하지 못한 구간은 combined로 표시하고 원인 분석에 사용한다.

- 제품 SHA/digest, workflow revision, OS image/Xcode build/Swift/SDK/arch,
  Package.resolved·manifest hash, destination/configuration/flags를 원시 JSON에 남긴다.
- queue/setup/dependency/compile/test/DocC/artifact 시간과 전체 job 비용을 분리한다.
  같은 계측과 조건으로 baseline 3회 이상, 후보 cold 1회 및 warm 3회 이상을 수집한다.
  실행 순서를 교차하고 환경이 바뀐 표본은 별도 묶음으로 남긴다. 빠른 표본만 선택하지 않는다.
- 먼저 실제 중복 compile/resolve 원인을 확인한다. 캐시 재도입은 측정된 비용을 줄일 근거가 있을 때만
  후보로 삼고, 현재 cache 금지 fixture 변경에도 측정 근거를 남긴다. 전체 `.build` 공유는 하지 않는다.
- warm 중앙값 20% 단축은 목표다. cold regression 5% 초과면 원인을 재검토한다.
  1차 표본으로 이득이 불명확하면 후보를 축소/제거하고 결과를 기록한다. 무기한 재실행하지 않는다.
- core step뿐 아니라 다른 workflow, 총 runner 시간과 검증 항목 보존을 함께 비교한다.
  source lint/DocC/consumer/API/coverage/performance/sanitizer/platform 검사는 생략하지 않는다.

성과가 없더라도 정직한 측정·롤백 보고가 단계 산출물이다. 성능 목표 미달 자체는 F1/F2와 같은
제품 배포 차단 결함이 아니다. 통계적으로 확실한 개선이라고 말할 근거가 부족하면 그렇게 명시한다.

## 8. 주요 선택과 대안

| 선택 | 대안 | 선택 이유 / 재검토 조건 |
| --- | --- | --- |
| 자동 flush만 별도 보호, 공개 save 계약 보존 | 모든 save를 복원 완료 전 금지 | 대안은 앱의 의도적 복구/저장을 막는 호환성 위험. 기존 소유권 상태로 부족할 때 내부 모델만 재검토 |
| 복원 결과·revision·소유권으로 저장 판단 | status == active 또는 phase == completed만 사용 | 표시 status와 실제 수락 여부는 다름. rejected/deferred 경계를 반드시 검증 |
| transform catch와 크기 검사를 분리 | 새 오류 계약으로 문서 수정 | 6.0.0 호환성을 유지하는 minor 후보이며 소비자의 recovery 분기를 보존해야 함 |
| 실제 context를 required로 지정 | CI 문서와 관행만 유지 | 문서만으로 병합 보호가 되지 않음. context가 불안정하면 먼저 workflow 보고 구조 수정 |
| 측정 후 이득이 있는 최적화만 유지 | 제거한 캐시를 다시 기본 적용 | 이전 후보가 회귀했음. 도구체인/runner/병목이 달라졌을 때 재검토 |

## 9. T706 — 완료와 배포 판단

**RRR-AC-08**의 실행 순서:

1. F1/F2 재현 실패→수정 후 통과 증거와 정상 대조군을 남긴다. 저장된 route payload는 로그에
   남기지 않고 byte count, 결과, revision, write 횟수만 기록한다.
2. `swift test --jobs 2 --no-parallel`, 변경된 플랫폼/runtime 및 외부 consumer,
   macro/API/DocC/lint 검사를 수행한다. 전체 gate는 최종 후보에서 묶어 실행한다.
3. `./scripts/principle-gates.sh --platforms=all`과 coverage/performance/ASan/TSan/지원 플랫폼의
   기존 gate를 유지한다. 신규 회귀가 sanitizer 필터·native host target에 실제 포함되는지 확인한다.
4. 작업별 coherent commit과 push/PR을 진행하고 로컬·upstream·원격 SHA를 대조한다.
   최종 반영 SHA의 원격 workflow 7개와 하위 job 결과를 확인한다. 이전 SHA의 성공을 재사용하지 않는다.
5. RRR-AC-01~08 및 영향을 받은 RXP 항목의 통과/실패/미실행을 재대조한다. 발견된 호환성 위반이나
   원본 파일 손실이 남으면 발행 보류. CI 보호의 운영 적용 상태와 최소 OS 검증 한계도 별도 표기한다.
6. 버전·README·CHANGELOG와 exact-tag 소비자·GitHub Release·versioned DocC/latest의 준비 상태를
   [RELEASING.md](../RELEASING.md)에 따라 정리한다. 수정 검증 완료와 실제 발행을 분리한다.

각 작업의 검증까지 통과한 변경만 커밋 단위로 묶는다. 이후 실행 요청은 위 구현·검증·commit/push·재평가를
대상으로 하며, bare `6.1.0` 태그/Release 생성과 공개 문서 배포는 별도 발행 단계다.

## 10. 복구와 미확정 사항

- schema 변환이나 원본 삭제를 추가하지 않는다. 잘못된 후보의 자동 저장을 막으며 이미 잃은 파일을
  되살린다고 약속하지 않는다. 향후 새 후보에서 문제가 생기면 발행을 중단하고 해당 변경을 재검토한다.
- CI 설정은 적용 전 원본을 보관하고 실패/누락 check의 영구 대기가 확인되면 해당 설정 diff만 되돌린다.
  기존 보호를 통째로 해제하지 않는다. 빌드 최적화도 독립 커밋으로 되돌릴 수 있게 한다.

| 미확정 사항 | 담당 / 해소 시점 | 막는 단계 |
| --- | --- | --- |
| 내부 저장 가능 근거를 기존 필드로 표현할지 전용 내부 타입으로 둘지 | 구현 담당 / T701 실패 회귀와 상태 전이 대조 후 결정 | T701 구현 완료 |
| 실제 required check 이름·App ID·bypass 및 설정 권한 | 유지관리자와 실행 담당 / T704 fresh read | CI 설정 적용 완료 |
| 최소 지원 OS runtime 확보 여부 | 검증 담당 / T703 환경 inventory | 해당 OS 검증 완료 주장 |
| 최적화할 실제 병목과 개선 폭 | 실행 담당 / T705 계측 | 성능 개선 성과 주장 |

새로운 제품 정책 결정을 요구하는 미확정 사항은 현재 없다. 문서의 Draft 상태는 구현·발행 완료를
의미하지 않으며, 실제 검토·승인과 단계별 증거가 생긴 시점에 이력으로 추가한다.

## 11. 이력

- 2026-09-21 v0.1: F1/F2 재현과 현 소스 재확인에 근거하여 후속 실행 계획 작성. 제품·CI 설정 변경 없음.
- 2026-09-21 v0.2: T701~T703 구현. 692 tests / 87 suites, 외부 소비자 9 tests / 2 suites,
  public API·문서·lint와 전체 플랫폼 principle gate 통과. 원격 SHA·ruleset·CI 측정은 진행 중.
- 2026-09-21 v0.3: 구현 SHA `7267b565`의 원격 workflow 7개 성공. principle core 첫 표본
  696초와 세부 구간을 기록. 같은 제품 source의 후속 표본·ruleset 적용·최종 판정은 진행 중.

## 12. 저장 실행 경계 후속 수정 — 2026-09-21

`14e81a7f` 재검토에서 기존 driver의 자동 저장이 storage actor의 load 뒤에 대기하다가,
stop 후 새 driver가 기록한 파일을 뒤늦게 덮는 F3를 재현했다. T701~T703의 앞선 완료 표시는
당시 실행한 회귀 범위의 이력이며 RRR-AC-02 모든 조합의 충족을 뜻하지 않는다.

- RRR-T707 / AC-02~03: durability ticket의 자동 저장 취소 가능 여부를 기록한다. 취소/교체는
  미시작 ticket을 무효화하고 storage actor는 동기 I/O 직전 유효 ticket을 원자적으로 확보한다.
  명시 save는 stop/caller 취소에도 기존 계약을 유지한다. 이미 시작된 I/O의 rollback은 보장하지 않는다.
- RRR-T708 / AC-01~02·05: enqueue/finish 신호로 순서를 제어하는 실제 파일 회귀를 추가한다.
  자동/scene flush × stop/마지막 detach, 새 navigation/명시 save/삭제를 검증한다.
  mounted scenePhase 테스트는 flush 완료를 기다린 뒤 파일 bytes를 검사한다.
- RRR-T709 / AC-05~08: iOS 18.6 실제 background→프로세스 종료→재실행을 전용 probe로 확인한다.
  변경 최종 SHA에서 required CI를 통과시키고 아래 미검증 범위와 함께 보고한다.

성능 기록 정정: 696초/587초 두 표본과 과거 소스의 712초 기준선 차이는 최적화 효과를
입증하지 않는다. RRR-AC-07의 동일 소스 baseline/후보 3회 이상 비교는 미완료이며,
관측 차이 9.9%를 성능 개선율로 사용하지 않는다. 이 수정은 CI 성능 최적화를 추가하지 않는다.

운영 기록 정정: main ruleset 19074564의 strict required checks 24개 적용과 `14e81a7f`의
7개 workflow 성공은 재확인했다. 재검토·추가 수정의 완료 여부는 최종 SHA 증거로 별도 판단한다.

T707~709 로컬 결과: 취소 네 조합의 수정 전 실패·수정 후 통과, 명시 save 및 최신 명령 대조군,
실제 iOS 18.6 background→종료→재실행과 host 12개 테스트를 확인했다.
[후속 증거](review-evidence/2026-09-21-storage-execution-cancellation.ko.md)에 검증 범위와
이전 계획에서 여전히 미검증인 범위를 함께 기록했다. 전체 root 695 tests / 88 suites 통과.
