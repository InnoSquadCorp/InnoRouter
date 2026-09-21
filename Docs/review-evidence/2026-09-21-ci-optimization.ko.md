# 2026-09-21 CI 중복 제거·cache 측정 기록

| 항목 | 값 |
| --- | --- |
| 측정 상태 | 완료 — dependency cache 후보는 회귀로 제거 |
| 기준 SHA | `32edfffd3e3bb3cea92d5b2650b00201f6b0fee8` |
| 후보 SHA | `8fa20ea075d952726d27b75d9ab4eb7dd847a54a` |
| 제품 소스 digest | 두 SHA 모두 `02eb736cb9e93ee8b391e80f721821e8b00e61d0bbe1683fca0d274e6895bfa7` |
| 도구체인 | GitHub `macos-26`, Xcode 26.6, Swift 6.3.3, ARM64 |
| 최종 선택 | 중복 DocC site/source lint 위임과 resolution 고정은 유지, `actions/cache`는 제거 |

제품 소스 digest는 `Package.swift`, `Sources`, `Tests`, `Examples`,
`ExamplesSmoke`, `ConsumerSmoke`, `MigrationSmoke`, `NativeSceneSmoke`의 tracked
tree object를 합산하되 새 resolution 파일은 제외해 계산했다. queue는 runner 가용성에
따라 크게 달라졌으므로 아래 성능 판정에서 제외하고 job과 핵심 step의 시작·종료 시각만
사용했다. 모든 측정 실행은 성공했다.

## 통합 gate 반복 측정

기준선은 [principle-gates run 35545516398](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35545516398)의
세 attempt다. 후보는 [run 35547677303](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35547677303)에서
cache 비활성, exact miss, warm hit 세 번을 순서대로 실행했다.

| 구간 | 핵심 step(초) | job(초) | 판정 |
| --- | ---: | ---: | --- |
| 기준선 3회 | 544 / 746 / 712, 중앙값 **712** | 558 / 761 / 724, 중앙값 **724** | 비교 기준 |
| 중복 gate 제거 + cache 비활성 | 570 | 584 | 단일 표본 19.9% / 19.3% 단축. 반복 중앙값 성과로 주장하지 않음 |
| dependency cache exact miss | 684 | 710 | cold regression 없음. 성공 뒤 cache 저장 |
| dependency cache warm 3회 | 539 / 836 / 761, 중앙값 **761** | 558 / 859 / 780, 중앙값 **780** | 기준선보다 **6.9% / 7.7% 느림** |

miss 로그에서 `Cache not found`를 확인했고 성공 뒤 154,728,541바이트 archive가
저장됐다. 세 warm 실행은 같은 exact key의 hit와 실제 gate 실행을 모두 확인했다.
첫 hit만 빠르고 나머지 두 실행이 느렸으므로 20% 목표를 달성한 것으로 볼 수 없다.
후보 cache와 repository 변수는 제거했다.

## 다른 workflow 대조

DocC 기준선은 [run 35545516391](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35545516391),
warm 후보는 [run 35547677378](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35547677378)이다.

| workflow | no-cache 또는 비활성 | warm hit | 판정 |
| --- | --- | --- | --- |
| DocC | build 120 / 136 / 206초, 중앙값 **136** | 108 / 167 / 218초, 중앙값 **167** | 22.8% 회귀, 제거 |
| coverage | 기준 test 114초, 비활성 121초 | test 141초 + restore 9초 | 회귀, 제거 |
| migration | 기준/ hit 핵심 step 모두 115초 | restore 7초로 job만 증가 | 이득 없음, 제거 |
| performance | 비활성 핵심 두 step 합계 213초 | hit도 213초 + restore 6초 | 이득 없음, 제거 |
| sanitizers | 비활성 address/thread 257/217초 | hit 215/247초 | 방향이 엇갈려 반복 가능한 이득 없음, 제거 |

플랫폼 workflow에는 cache를 적용하지 않았다. 각 matrix cell이 격리된 Xcode
DerivedData를 사용하므로 root SwiftPM cache를 여러 runner에 내려받는 비용만 늘어날 수
있기 때문이다. 후보 플랫폼 최초 실행에서는 Inspector UI가 switch 탭 직후 값을 기다리지
않아 1회 실패했고 [failed attempt](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35547677358/attempts/1)의
나머지 13개 job은 성공했다. 실패 job 재실행은 성공했다. 최종 후보는 두 동일 패턴을
predicate value 대기로 보강한다.

## 요구사항 판정

- RXP-AC-501: 같은 제품 소스 digest에서 queue와 실행 시간을 분리하고 baseline,
  disabled, miss, warm을 수집했다.
- RXP-AC-502: exact toolchain/SDK/architecture/resolution key, miss fallback, cache 비활성
  경로를 검증했다. 성능 회귀 때문에 후보 자체를 제거해 stale binary 신뢰 경계도 남지 않는다.
- RXP-AC-503: DocC site와 source lint는 sibling required job에 위임하되 standalone 및
  release `principle-gates.sh`는 전체 gate를 계속 실행한다. cache hit에서도 테스트를
  생략하지 않았다.
- RXP-AC-504: warm 20% 단축 목표는 **미달**이다. 미달 결과를 그대로 기록하고 cache를
  제거했다. 검증된 개선은 중복 gate 제거이며 단일 cache 비활성 표본은 19.9% 단축됐다.

최종 구현은 [GitHub dependency cache reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)의
cache 동작을 검토하고 실측한 뒤, 이 저장소에서는 채택하지 않는 것으로 결정했다.
