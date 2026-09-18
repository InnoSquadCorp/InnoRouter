# InnoRouter 복원 경계 재설계 실행 기록

## 기준과 범위

- 계획: [복원 경계 재설계·회귀 수정 계획](../2026-09-18-restoration-boundary-remediation-plan.ko.md), Draft 0.3
- 승인 상태: 유지관리자의 실행 요청은 기록됐으나 계획 문서의 명시적 Approved 전환·승인일은 미기록
- 실행 전 기준: `4451d7af999417d31ec3832d4c9c558d96c9deb7`
- 회귀 도입: `102c03ca3a7ee911f44c8d58df2cbea9ac32f840`
- 최근 태그: `6.0.0` = `f6abef8e` (2026-09-16)
- 작업 브랜치: `fix/restoration-boundary`
- 포함: T01~T08. 제외: T09(version cut, tag, push, Release·DocC 발행)
- 감사 신뢰도: **provisional**. 기준 계획이 Draft이고 원격 CI가 아직 실행되지 않았다.

## 1. 출시 상태 확인

`git merge-base --is-ancestor 102c03ca 6.0.0`이 거짓이고
`git log 6.0.0..HEAD`에 `102c03ca`가 포함된다. 회귀 표면
(`restorationTabBaseline`, `RouterTabRestoration.swift`, `prepareRestoredState`
호출부 3곳)은 전부 이 커밋에서 생겼고 어떤 태그에도 없다. 영향받은 사용자는 없다.

`git show --stat 102c03ca`는 신규 public 심볼 추가가 없음을 보여준다. 변경된 것은
기존 `restore`/`restorePartially`의 동작과, 그 동작을 단언하는 downstream 테스트
`tabRestorationReconcilesPublishedTopology`다.

`b4d33be6`은 revert 범위가 아니다. 해당 커밋의 주 내용은 macro diagnostic,
`RouterSplitHost`, `RouterByteStore`, deep-link expansion이다.

## 2. T01 — revert 이전 반례 실패 기록

`swift test --filter RouterRestorationBoundary`를 `4451d7af` 기준 트리에서 실행한 결과:

| 테스트 | 실패 내용 |
| --- | --- |
| 미검증 route 재유입 | 적용 상태 `[.detail, .legacy]` vs validator 관찰 `[.detail]` |
| 초기 presentation 유지 | `.duplicatePresentation(…011)` 로 복원 전체 실패 |
| tabs→stack 자체 snapshot 왕복 | `.incompatibleNavigationTopology(/)` |
| 탭 제거 후 자체 snapshot 왕복 | branch `[home, settings]` vs 기대 `[home]` |
| recovery fallback 적용 | `.incompatibleNavigationTopology(/)` |
| (대조군) 새 탭 도달 가능 | 통과 |

6 tests / 1 suite, 5 issues. 대조군만 통과했다.

### 2.1 계획 R1 서술의 정정 사항

계획 R1은 presentation ID 중복으로 복원이 실패한다고 기술했고, 위 두 번째 행이 그
사실을 확인한다. 다만 같은 UUID를 다른 scope에 두는 시나리오는 revert 이후에도
`RouterMutationError.presentationIdentityConflict`로 거절된다. 이는 `102c03ca`
이전부터 있던 의도적 불변식(presentation 정체성은 한 transition에서 scope를 옮길 수
없음)이며 본 작업의 회귀가 아니다. 따라서 해당 반례는 서로 다른 presentation ID를
쓰는 형태로 고정해, "snapshot에 없던 presentation이 적용 상태에 남는가"만 검사한다.

## 3. T02 — revert

`git revert --no-commit 102c03ca`가 충돌 없이 적용됐다. `102c03ca` 이후
`Sources/`·`Tests/`를 수정한 커밋이 없어 3-way 병합이 필요하지 않았다.

revert 직후 `RouterRestorationBoundary` 6 tests 중 R1/R2 반례 5개가 통과하고,
대조군은 `branchIDs.contains("profile") == false`로 실패했다. 이는 계획이 예상한
미지원 상태 복귀다. 대조군은 `withKnownIssue`로 보류 표시한 뒤 T04에서 해제했다.

전체 스위트: 644 tests / 81 suites 통과, known issue 3건(대조군 2 + 기존 1).

## 4. T03~T05 — 명시적 topology

`RouterTabRestorationTopology`는 순서 있는 scope ID만 보관한다. route,
presentation, badge, Store, View를 보관하지 않으므로 보정이 payload를 복원 상태로
옮길 수 없다. 보정은 decode된 state와 이 값만 읽는 순수 함수다.

| 경로 | 연결 |
| --- | --- |
| `RouterStore.restore(from:using:tabTopology:)` | 신규 overload, 기존 signature는 exact 유지 |
| `RouterStore.restore(from:using:recovery:tabTopology:)` | `.recovered`는 보정 생략 |
| `RouterStore.restorePartially(…tabTopology:)` | 보정 → validator 순서 |
| `RouterRestorationDriver.init(…tabTopology:)` | topology는 driver 생명주기 소유 |
| `RouterTestStore` | production overload 그대로 위임 |
| `RouterTabHost(store:catalog:allowingOrphanedBranches:)` | 기존 strict initializer는 exact 집합 일치 유지 |

`RouterTabRestorationTopology` 12 tests, `RouterRestorationBoundary` 6 tests 통과.
전체 스위트 654 tests / 82 suites 통과, known issue 1건(기존).

### 4.1 공개 API diff

`./scripts/check-public-api.sh` 기준 **제거 0건**. 초기 구현에서 driver의 기존 init을
`convenience`로 바꾸자 선언 문자열 변화로 `-` 라인 1건이 생겨, 두 init을 모두
designated로 되돌려 제거를 0으로 만들었다. `RouterRestorationDriver`는 `final`이라
호출자에게는 어느 쪽도 차이가 없다.

예산: InnoRouter 1156 → 1172, InnoRouterTesting 250 → 252, Inspector 207 유지.
`Baselines/PublicAPI/symbol-budgets.tsv`와 `Docs/v6-public-api-boundary.md`를 함께 갱신했다.

## 5. T06 — sanitizer 실제 실행

| suite | TSan | ASan |
| --- | --- | --- |
| RouterRestorationBoundary | 실행 | 실행 |
| RouterTabRestorationTopology | 실행 | 실행 |
| RouterTabHost | 실행 | 실행 |
| Macro-first host deep links | 실행 | 실행 |
| Native host runtime | 실행 | 실행 |
| @Router deep-link behavior | 실행 | 실행(신규) |

- thread: 364 tests / 42 suites 통과, known issue 1건, exit 0
- address: 352 tests / 46 suites 통과, exit 0

## 6. T07 — 검사·문서

- G2 증명: 정규식 `^- Implementation (?:state\|status): .*published`가
  `- Implementation state: unpublished as of 6.0.0`에 매칭됨을 확인했다. 새 검사는
  whole-word 판정으로 이를 거절한다.
- G1 증명: `RELEASE_VERSION=6.1.0 ./scripts/check-docs-consistency.sh` exit 1,
  `RELEASE_VERSION=6.0.0` exit 0.
- fixtures: unpublished 2종, 버전 없는 발행 주장, 중복 implementation state,
  중복 document status, 미배포 한국어 행, 버전 없는 배포 주장 거절.
  patch/minor/prerelease 정상 lifecycle 3종 통과.
- README 양 언어·SwiftUI DocC·CHANGELOG 갱신. `check-docs-code-blocks.sh` 통과.

## 7. 인수 기준 대조

| AC | 상태 | 근거 |
| --- | --- | --- |
| RBR-AC-001 | 충족 | 2절 3~4행 실패 → 3절 통과 |
| RBR-AC-002 | 충족 | 2절 1~2행 실패 → 3·4절 통과 |
| RBR-AC-003 | 충족 | `RouterTabRestorationTopology` 대조군·topology suite |
| RBR-AC-004 | 충족 | keepsExistingScopesExactly, orphanBranchesArePreservedInOrder, removedSelectionFallsBackToFirstScope |
| RBR-AC-005 | 충족 | recoveryFallbackIsNotReconciled |
| RBR-AC-006 | 충족 | partialRestorationValidatesTheReconciledCandidate |
| RBR-AC-007 | 충족 | equivalentSnapshotIsUnchanged |
| RBR-AC-008 | 충족 | RouterTabHost strict/orphan initializer |
| RBR-AC-009 | 충족 | driverTopologyBelongsToItsOwnLifetime, driverWithoutTopologyRestoresExactly |
| RBR-AC-010 | 충족 | 5절 sanitizer 로그 |
| RBR-AC-011 | 충족 | 6절 |
| RBR-AC-012 | 8절 참조 | |
| RBR-AC-013 | 미충족 | T09 미착수 |
| RBR-QA-001 | 미실행 | 실기기·GUI 실행 환경 없음 |

## 8. 남은 작업

- RBR-QA-001 수동 QA
- T09: `6.1.0` version cut, changelog cut, tag, push, Release·DocC 발행
- 원격 CI는 push 전이므로 미실행
