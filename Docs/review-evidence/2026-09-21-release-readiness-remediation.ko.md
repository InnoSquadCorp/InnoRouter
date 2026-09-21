# 2026-09-21 6.1.0 배포 전 복원 안전성·호환성 개선 증거

| 항목 | 값 |
| --- | --- |
| 계획 | `Docs/2026-09-21-release-readiness-remediation-plan.ko.md` |
| 기준 SHA | `b82b2a81ec241ed21e620741ed5aa8892800f189` |
| 문서 상태 | Draft — 구현 SHA 원격 검증 완료, 운영 설정·최종 문서 SHA 검증 진행 중 |
| 구현 상태 | 부분 구현 |
| 배포 상태 | 미배포 |

## 구현 결과

### RRR-T701 — 자동 생명주기 저장 보호

- scene lifecycle은 공개 `save()` 대신 attachment와 복원 결과를 확인하는 내부 flush를 사용한다.
- load/decode/migration/validation 실패, rejected/deferred 후보는 별도 commit이 없으면 원본을 덮지 않는다.
- noSnapshot, applied/unchanged, deferred 승인과 독립 navigation commit은 저장할 수 있다.
- 공개 `save()`와 `removeSnapshot()` 계약은 바꾸지 않았다.
- 자동 저장은 encode 뒤와 durability turn 획득 뒤 generation/storage epoch를 다시 확인한다.
- 완료된 driver가 detach 후 재연결돼도 이미 확보한 저장 자격을 잃지 않는다.

직접 증거:

- 정상 codec으로 생성한 1,300바이트 snapshot이 storage 한도 때문에 복원 실패한 뒤 lifecycle flush를 호출해도 파일 bytes와 failed status가 유지된다.
- 같은 실패 뒤 새 navigation commit을 만들면 최신 state가 저장된다.
- 실제 SwiftUI hosting root에서 `.active → .background` 전환 시 실패한 restore는 save 0회, 새 navigation 이후 전환은 save 1회다.
- partial deferred/rejected 후보는 lifecycle flush로 저장되지 않고, terminal 승인 또는 독립 navigation 뒤에만 저장된다.

### RRR-T702 — migration 오류 호환성

- 앱 migration transform의 모든 오류는 6.0과 같이 `migrationFailed(from:to:message:)`로 감싼다.
- migration 반환 payload의 codec 한도 검사는 transform catch 밖에서 수행해 새 typed limit 오류를 유지한다.
- 제한 없는 codec, 명시 recovery와 외부 소비자에서 기존 오류 분기를 직접 검증했다.

### RRR-T703 — 검증 공백 보강

- 실제 `RouterFileSnapshotStorage`에서 partial normalization 후 새 driver가 retired route 없이 재실행된다.
- metadata 확인 뒤 파일이 증가하면 stream 한도가 초과를 잡고, 축소되면 실제 작은 bytes를 반환한다.
- `Int.max` 한도에서 overflow 없이 정상 파일을 읽고 쓴다.
- `@TabItem(id:)`의 empty, whitespace-only, interpolation, dynamic expression을 각각 거절한다.
- 완료 driver의 detach/reattach와 mounted scene lifecycle을 추가했다.

## 로컬 검증

| 검증 | 결과 |
| --- | --- |
| `swift test --jobs 2 --no-parallel` | 692 tests / 87 suites 통과, 기존 의도된 known issue 1건 |
| 외부 소비자 | 9 tests / 2 suites 통과 |
| public API | InnoRouter 1193/1193, Inspector 207/207, Testing 252/252; baseline 변경 없음 |
| 문서·source lint | 통과 |
| `principle-gates.sh --platforms=all` | 통과 |
| 플랫폼 공개 interface | iOS 18, Mac Catalyst 18, macOS 15, tvOS 18, watchOS 11, visionOS 2 통과; iPadOS는 동일 iOS simulator destination 중복 빌드 생략 |

테스트 합계는 root package의 일곱 test product 합산이다. 외부 소비자와 generated scenario는
별도 증거로 분리한다. Xcode 생성 resource accessor의 scoped-import 경고는 있었지만 각
플랫폼 interface validator와 전체 gate는 통과했다.

## 남은 단계

- [x] 구현 commit `7267b56564c78cdc60f1a2abd9d22f0229b50aa3` push 후 로컬·origin/main·원격 SHA 일치 확인.
- [x] 구현 SHA에서 workflow 7개와 하위 job 성공 확인.
- [ ] main ruleset에 실제 GitHub Actions check context를 연결하고 다시 조회.
- [ ] 같은 제품 소스 digest의 docs-only 후속 SHA로 principle core step 표본 2개를 더 수집해 기존 712초 baseline과 비교.
- [ ] 계획의 RRR-AC-01~08 최종 대조와 6.1.0 발행 가능성 재판정.

구현 SHA 원격 workflow:

| workflow | run | 결과 |
| --- | --- | --- |
| principle-gates | `35559119580` | success — gates/lint/changelog-sync/release-contract 포함 |
| platforms | `35559119677` | success — 14 jobs |
| coverage | `35559119617` | success |
| sanitizers | `35559119648` | success — address/thread |
| performance-smoke | `35559119685` | success |
| migration-smoke | `35559119750` | success |
| docs-ci | `35559119774` | success |

## CI 시간 표본

resolution 파일을 제외한 제품·테스트·consumer source digest는
`1ab2fdbc65ad77647c0b06a5ef5e4acace9744b20db77afcaab14a0698f9b3e6`다.
후속 문서 commit은 이 digest를 바꾸지 않는다.

| 표본 | core step | job | 초기 dependency/compile | root test | 비고 |
| --- | ---: | ---: | ---: | ---: | --- |
| 기존 no-cache baseline 중앙값 | 712초 | 724초 | 미분리 | 미분리 | 3회 기준선 |
| 구현 SHA `7267b565`, run `35559119580` | 696초 | 715초 | 114.33초 | 6.22초 | 첫 후보 표본, baseline 대비 2.2% 단축 |

첫 후보의 dependency 로그는 cache fetch 4.82초와 version compute 누적 9.98초를 보였다.
외부 consumer 구간은 resolve 시작부터 최종 성공까지 약 330초로 가장 큰 관찰 구간이었다.
GitHub가 해당 성공 run의 수동 rerun을 repository admin 권한 오류로 거절했으므로, 같은 제품
source digest를 유지하는 자연스러운 문서 후속 commit의 새 push run을 추가 표본으로 사용한다.
반복 중앙값을 확보하기 전에는 개선 성과를 확정하지 않는다.

현재 결과는 수정 후보의 로컬 검증 완료를 의미한다. runtime version, tag, GitHub Release,
versioned DocC와 `/latest/`는 변경하거나 발행하지 않았다.
