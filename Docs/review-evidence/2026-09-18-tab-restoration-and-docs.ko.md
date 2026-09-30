# InnoRouter 탭 복원·문서 정합성 실행 및 명세 대조 기록

> 2026-09-18 정정: 아래 `구현 완료 7`, `부분 / 누락 / 모순 0`, `로컬 검증 완료 10`은
> 재검토 이전 판정이다. 초기 payload 복사와 생성 시점 topology 고정으로 인한 회귀,
> native assertion 및 sanitizer 대상 누락이 확인되어 관련 완료 판정을 재개방한다.
> 기존 통과 실행 사실은 보존하되 현재 완료 근거로 일괄 재사용하지 않는다.
> [후속 계획과 인수 기준](../2026-09-18-restoration-boundary-remediation-plan.ko.md)을 참조한다.

## 기준과 범위

- 계획: [탭 복원·문서 정합성 개선 작업계획](../2026-09-18-tab-restoration-and-docs-plan.ko.md), Draft 0.2
- 승인 상태: 결정 책임자의 실행 요청은 기록됐으나 계획 문서의 명시적 Approved 전환·승인일은 미기록
- 수정 전 기준: `b4d33be67ccd8616718f1dafb94093782791e807`
- 런타임 구현: `102c03ca` (`fix: reconcile restored tab topology before commit`)
- 포함: snapshot/partial/driver tab 복원, policy·revision, host/deep-link/consumer/platform 회귀, 문서 lifecycle·API 예산 검사, local consumer/migration gate 재현성
- 제외: tag, GitHub Release, versioned/latest DocC 발행, 실기기·VoiceOver 사용성
- 감사 신뢰도: **provisional**. 기준 계획이 Draft이므로 구현 증거는 충분해도 제품 문서 승인으로 간주하지 않는다.

## 근본 원인과 구현

`RouterTabHost`는 catalog를 렌더링했지만 snapshot의 tab branch 집합이 현재 앱과
달라도 canonical state를 보정하지 않았다. 그래서 화면에 보이는 새 tab의 scope가
없어 selection과 push가 `missingScope`로 거절됐다.

`RouterStore`가 생성 시점의 root tab topology를 복원 기준선으로 보존하고,
snapshot 또는 partial restoration의 후보를 정책 실행 전에 순수 값으로 정합화하도록
수정했다. 같은 ID의 branch와 badge/history는 보존하고, 현재 앱에만 있는 branch는
초기 상태를 사용하며, obsolete selection은 초기 selection으로 되돌린다. orphan
branch는 명시적 schema migration을 위해 유지한다. 정합화된 후보는 기존 policy,
stale/cancellation, 단일 commit/revision 경로로 적용된다. 일반 `RouterPlan.apply`는
계속 exact하며, root·branch topology가 호환되지 않는 snapshot은 typed error로 실패한다.

## 범위 요약

| 측정 | 수 |
| --- | ---: |
| 기능 요구사항 | 7 |
| 구현 완료 | 7 |
| 부분 / 누락 / 모순 | 0 |
| 인수 기준 | 11 |
| 로컬 검증 완료 | 10 |
| 발행 뒤에만 검증 가능한 기준 | 1 (`TRD-AC-011`) |
| 요구 밖 구현 | 0 |

## 요구사항 증거 행렬

| 요구사항 | 인수 기준 | 구현 상태 | 코드 근거 | 검증 범위 | 테스트 / 증거 |
| --- | --- | --- | --- | --- | --- |
| TRD-FR-001 | AC-001, 002, 004 | implemented | `RouterTabRestoration.prepareRestoredState` | covered | `snapshotRestorationReconcilesTabs`, downstream consumer, round trip |
| TRD-FR-002 | AC-002, 003 | implemented | restoration selection fallback, `RouterTabHost.selectionBinding` | covered | current-tab select/push, restored deep-link selection, iPhone/iPad mounted tests |
| TRD-FR-003 | AC-001, 003, 004 | implemented | current-order branch merge + orphan append + badge merge | covered | history/badge/orphan assertions, repeated restore equality |
| TRD-FR-004 | AC-005, 006 | implemented | `RouterStore+Snapshot`, `RouterPartialRestoration`, existing execution pipeline | covered | policy proposed-state assertion, rejection/revision 0, driver and partial entry points, existing stale/cancel suites |
| TRD-FR-005 | AC-006, 007 | implemented | initial store topology baseline; exact `.apply` unchanged; incompatible shape error | covered | exact-plan host test, manual catalog validation, root-shape rejection, platform regression |
| TRD-FR-006 | AC-008, 011 | implemented | strategy/spec/addendum lifecycle fields and release record | covered locally / release deferred | metadata checker and 6.0.0 historical release evidence; next tag not created |
| TRD-FR-007 | AC-009 | implemented | `check-doc-metadata.py`, `test-check-doc-metadata.sh`, docs consistency gate | covered | valid lifecycle states pass; ambiguous status and budget drift fixtures fail |

## 검증

- package: 644 tests / 80 suites 통과; 기존 known issue 1건
- focused: tab/driver/partial 32 tests, downstream public consumer 8 tests
- native: iPhone 27.0 및 iPad 26.5 Simulator platform suites 각각 12 tests 통과; 새 tab restore와 mounted host test 이름 확인
- sanitizer: TSan 331 tests / 37 suites, ASan 295 tests / 40 suites 통과
- coverage: gated 89.58% (16,582/18,510), comprehensive 84.50% (19,472/23,044)
- performance: release median 7개 시나리오 모두 예산 통과
- compatibility: published 5.2.1과 현재 macro-first probe 모두 `["home","settings"]`
- integration: `principle-gates.sh --platforms=all` 통과; public API 1,156 / 207 / 250 유지
- 알려진 경계: generated `resource_bundle_accessor.swift`의 scoped-import interface 경고는 기존 toolchain 경고이며 build/interface는 통과했다. iPad suite의 기존 stack mount 한 건은 69.96초였지만 새 tab restore/mount 테스트는 각각 0.008초/0.002초 미만에 통과했다.

## 다음 gate

1. 문서와 gate 변경을 별도 커밋으로 저장하고 모든 커밋을 `main`에 push한다.
2. 정확한 원격 HEAD의 필수 CI 7개가 모두 성공하는지 확인한다.
3. 최신 공개 버전과 SemVer, changelog·runtime version·release metadata를 대조해 패치 배포 준비 여부를 판정한다.
4. 실제 발행이 승인되면 새 immutable tag 뒤 exact-version consumer, GitHub Release, versioned DocC와 `latest`를 확인해 `TRD-AC-011`을 닫는다.
