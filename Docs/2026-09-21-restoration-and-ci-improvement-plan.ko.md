# 복원 입력 한도·자동 부분 복원·명시적 탭 ID·CI 개선 계획

> 2026-09-21 실행 기록: 2단계 입력 한도를 구현했다. 기존 무제한 API를 유지하면서
> 파일·envelope·payload·migration 결과의 선택형 한도와 typed 오류를 추가했고,
> 전체 674 tests / 86 suites 및 API·문서·lint 검사를 통과했다. 이어서 3단계의
> validator 기반 자동 부분 복원·보고서·정상화 저장과 외부 소비자 검증을 완료했다.
> 4단계의 명시적 탭 ID·중복 진단·case rename 복원과 외부 macro 소비자도 구현했고,
> 전체 684 tests / 87 suites, 외부 소비자 8 tests / 2 suites, API·문서·lint 검사를 통과했다.
> 5단계는 CI 중복 gate 제거와 dependency cache 후보의 전후 측정을 완료했다. warm
> 중앙값이 6.9% 회귀해 cache 후보는 제거했고, resolution 고정과 중복 제거만 유지했다.

| 항목 | 내용 |
| --- | --- |
| 문서 상태 | Draft |
| 작성일 / 문서 버전 | 2026-09-21 / 0.1 |
| 기준 소스 | `c0d3a40fec0553d1f3a78b308cdcb24d8f93de1d` |
| 범위·순서 결정 | 사용자가 직전 평가의 **2 → 3 → 4 → 5** 순서로 계획 작성을 요청 |
| 결정 책임자 | 프로젝트 유지관리자(사용자) |
| 검토자 / 승인자 / 승인일 | 미기록 / 미기록 / 미기록 |
| 구현 상태 | 2~5단계 구현·측정 완료, 최종 SHA 원격 검증 대기 |
| 배포 상태 | 미배포 |
| 릴리스 방향 | 6.0.0 호환성을 유지하는 6.1.0 추가 후보. 구현·최종 검증 후 확정하며 이 문서는 발행을 수행하지 않음 |

이 문서는 새 개선 범위의 요구사항과 구현 순서를 구분해서 기록한다.
기존 RBR/TRD/FR6 작업의 ID, 완료 기록과 배포 이력은 변경하지 않는다.
이번 요청의 산출물은 계획이며 제품 코드·CI 설정 변경은 다음 구현 단계다.

## 1. 기준과 범위

### 확인한 현재 상태

- 기준 커밋은 문서·탭 복원 예제까지 반영된 clean main이다. 해당 SHA의 전체
  668 tests / 85 suites와 원격 CI 7개가 통과했다. known issue 1건은 테스트 도구의
  예상 진단 검증이며 미해결 제품 버그 수가 아니다.
- 실제 최신 배포는 6.0.0이다. runtime version도 6.0.0이며 6.1 변경 내역은 Unreleased다.
- `RouterAtomicFileStore.load()`는 파일을 통째로 읽는다. `RouterSnapshotCodec`에는
  encoded envelope / payload 크기를 제한하는 옵션이 없다.
- `restorePartially`에는 validator와 timeout이 있지만 자동 복원 driver의 initializer에는
  연결 지점이 없다. 기존 driver는 revision·generation·request family를 함께 관리한다.
- `@TabItem`의 scope ID는 생성된 `Tab.rawValue`, 즉 enum case 이름이다.
- CI에는 의존성/컴파일 산출물용 `actions/cache` 설정이 없다. 기준 실행의 통합 job은
  약 11.8분, 플랫폼 workflow는 대기를 포함해 약 21.9분, Inspector UI job은 약 9.8분이다.
  이 한 번의 실행은 개선 효과를 판정할 통계적 기준값이 아니다.

근거: [복원 안전성 기록](review-evidence/2026-09-19-restoration-safety.ko.md),
[통합 CI](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35540698966),
[플랫폼 CI](https://github.com/InnoSquadCorp/InnoRouter/actions/runs/35540699068),
[배포 규칙](../RELEASING.md).

### 포함 / 제외

포함은 아래 네 단계와 관련 API·문서·예제·회귀·소비자 검증이다.
직전 평가의 1번(최저 OS 실행 행렬/추가 수동 QA)은 이번 구현 범위에 넣지 않는다.
새 라우팅 엔진, cloud sync, 인증 구현, 자동 orphan 삭제, OS/Swift 하한 변경,
기존 snapshot schema 변경, 6.1 태그·Release 발행도 포함하지 않는다.

### 공통 제약

- 기존 public product 3개와 Store 단일 변경 권한을 유지한다.
- 기존 initializer와 macro 호출을 보존한다. 새 동작은 명시적으로 선택한다.
  이전에 허용하던 큰 파일을 기존 호출에서 갑자기 거절하는 기본값 변경은 하지 않는다.
- 기존 snapshot/report JSON 및 `.use` recovery, strict manual host, generic exact restore의
  의미는 유지한다. 변경이 필요하면 숨기지 않고 별도 설계·SemVer 판단으로 분리한다.
- accepted는 상태 변경 1회/ revision 1회, unchanged는 0회, rejected/cancelled/stale는 0회다.
- 숫자로 된 한도·timeout·cache 성과는 측정 또는 호출자가 지정한 설정과 연결한다.
  존재하지 않는 완료 증거나 성능 개선율을 기록하지 않는다.

## 2. 요구사항과 인수 기준

아래 FR은 필요한 동작이고, 3절의 기술 제안은 그 구현 방법이다.
각 AC는 구현 단계에서 작성·실행할 기준이며 현재 통과했다고 주장하지 않는다.

| 요구사항 | 관찰 가능한 동작 | 인수 기준 | 담당 작업 / 증거 |
| --- | --- | --- | --- |
| RXP-FR-201 | 파일 입력을 앱이 정한 바이트 상한 안에서 읽고 초과를 구별한다. | RXP-AC-201: 한도-1/한도/한도+1, 다중 chunk, 파일 변경 경계에서 제한 초과를 놓치지 않으며 전체 파일 읽기로 우회하지 않는다. 0/음수 설정은 오류, 큰 정수 연산은 overflow 없음. | RXP-T201 / bounded-reader·실제 파일 테스트 |
| RXP-FR-202 | codec이 envelope·payload·migration 결과의 크기를 검사한다. | RXP-AC-202: 초과 envelope는 JSON decode 전, 초과 payload는 route decode 전, 초과 migration 출력은 다음 migration/decode 전 거절. 정상 schema/migration/구버전 데이터는 동일 결과. | RXP-T202 / decoder·migration 호출 canary |
| RXP-FR-203 | 제한 실패는 기존 파일·Store에 실패한 후보를 반영하지 않는다. | RXP-AC-203: encode/save 초과도 typed error로 종료하고 기존 파일을 보존. direct/driver/partial 실패의 state·revision 보존, recovery 호출 여부·오류 종류 확인. 별도 정상 navigation 저장과 구분. | RXP-T203 / 파일·Store·recovery 통합 |
| RXP-FR-301 | 자동 복원이 앱의 route validator를 실행한 후보만 반영한다. | RXP-AC-301: decode→migration→선택적 topology→partial validation→정책→단일 apply. 중간 원본 apply 없음. keep/remove/replace·필수 fallback·presentation/window/immersive 결과가 직접 부분 복원과 동일. | RXP-T301 / driver·direct·TestStore 대조 |
| RXP-FR-302 | 검증 중 새 이동·중단·취소가 오래된 후보를 무효화한다. | RXP-AC-302: load/decode/validator/policy 대기의 각 경계에서 새 commit, stop, 마지막 host detach, driver 교체, caller 취소를 제어 가능한 barrier로 재현. 늦은 validator가 상태·보고서·새 worker 소유권을 변경하지 못함. | RXP-T302 / 생명주기 회귀·sanitizer |
| RXP-FR-303 | 복원 보고서와 실제 반영 결과를 구분해서 관찰한다. | RXP-AC-303: 기존 activation 반환형 유지. 새 partial outcome에 route·topology 보고와 transition 제공. 실패·noSnapshot·재시작 때 오래된 보고서를 새 시도 결과처럼 노출하지 않음. deferred 보고를 최종 성공으로 오인하지 않음. | RXP-T302 / report·deferral 테스트 |
| RXP-FR-304 | 받아들인 부분 복원 결과가 자동 저장·재실행까지 이어진다. | RXP-AC-304: applied 및 보정이 필요한 unchanged 결과를 저장 후 새 driver로 열었을 때 제거된 route가 돌아오지 않음. deferred는 수락될 때까지 후보 저장 없음. 저장 실패는 별도로 보고하며 성공한 navigation을 되돌리지 않음. | RXP-T303 / 실제 파일 round trip·저장 실패 |
| RXP-FR-401 | macro의 탭 scope ID를 코드의 case 이름과 별도로 지정할 수 있다. | RXP-AC-401: ID 미지정 시 기존 expansion/ID 동일. 지정 시 case 이름·표시명·순서 변경에도 지정한 scope ID가 유지. `Tab.rawValue`와 SwiftUI의 typed identity 의미는 유지. | RXP-T401 / macro expansion·behavior |
| RXP-FR-402 | 잘못되거나 충돌하는 ID를 컴파일 단계에서 설명한다. | RXP-AC-402: 빈/공백-only/보간/동적 표현식 및 effective ID 중복을 거절. 명시 ID끼리뿐 아니라 다른 탭의 기본 case-name ID와 충돌도 검출. escape 처리 후 실제 문자열 동등성 기준. | RXP-T401 / 실패 fixture·진단 위치 |
| RXP-FR-403 | 명시 ID를 모든 탭 관련 경로에서 일관되게 사용한다. | RXP-AC-403: select/badge/scoped navigation/기본 URL plan/topology/driver/report/외부 consumer가 동일 ID를 사용. 이전 case 이름을 ID로 고정한 뒤 case를 바꾸는 저장·복원 시나리오 통과. | RXP-T402 / 통합·consumer |
| RXP-FR-501 | CI의 대기·준비·빌드·실행 시간을 구분해 측정한다. | RXP-AC-501: 4단계 완료 소스를 기준으로 측정값·환경·source digest·cache hit/miss 보존. baseline 반복 실행과 후보 cold/warm 실행의 중앙값을 같은 조건에서 비교. | RXP-T501 / 측정 JSON·요약 |
| RXP-FR-502 | 캐시가 정확한 빌드 조건과 신뢰 경계를 보존한다. | RXP-AC-502: 도구체인/SDK/arch/manifest/의존성/구성 변경 시 부적합 binary 재사용 없음. miss·손상은 정상 재빌드. PR에서 만든 compiled artifact를 release의 검증 증거로 신뢰하지 않음. | RXP-T502 / cache key fixture·cold build |
| RXP-FR-503 | 중복 작업을 줄여도 필수 검증은 빠지지 않는다. | RXP-AC-503: package/macro/API/DocC/lint/consumer/coverage/performance/sanitizer/platform gate 목록과 실제 실행을 전후 대조. zero-test·negative consumer·bare tag/exact revision 검증 유지. | RXP-T503 / 실행 inventory·actionlint |
| RXP-FR-504 | 개선 효과가 재현되며 실패하면 쉽게 되돌릴 수 있다. | RXP-AC-504: warm 빌드 작업 시간 중앙값 20% 이상 단축을 목표로 측정. cold regression이 5%를 넘으면 원인 재검토. 목표 미달은 완료 성과로 포장하지 않고 범위 축소·재측정. cache 우회 경로 보유. | RXP-T504 / 전후 보고·우회 실행 |

## 3. 단계별 기술 제안

### 2단계 — 복원 파일 읽기·디코딩 한도

**선택:** 기존 호출은 보존하고, 명시적 limit 설정을 받는 overload를 추가한다.
전역 상수를 넣어 모든 앱의 허용 입력을 바꾸는 방식은 채택하지 않는다.

- Core에 `RouterSnapshotLimits` 같은 불변·Sendable 설정을 추가한다. 이름은 API spike에서
  확정한다. encoded envelope와 decoded payload 한도를 분리하며 유한 한도는 양수여야 한다.
- 기존 codec initializer는 유지한다. 새 `limits:` 필수 인자를 갖는 overload로 선택한다.
  새 예제의 유한 값은 앱이 선택한 예시라고 명시하며 라이브러리의 숨은 기본값으로 만들지 않는다.
- 기존 `RouterFileSnapshotStorage(fileURL:)`는 유지하고, 추가 인자를 갖는 throwing
  initializer로 읽기/쓰기 한도를 설정한다. codec envelope 한도와 storage 한도를 맞추는
  사용 예제를 제공한다.
- 공통 파일 helper는 `FileHandle` 등으로 chunk 단위 제한 읽기를 한다. file size metadata는
  조기 거절용일 뿐이며 실제 읽기에서도 cap을 적용한다. EOF와 초과 확인에 필요한 최소
  초과분만 읽고, `limit + 1` overflow와 handle 종료를 보장한다.
- shared helper를 쓰는 pending-link 저장소는 기존 기본 동작을 유지한다. pending-link의
  새 공개 한도 API까지 이 단계에 자동으로 확대하지 않는다.
- codec 입력 크기를 envelope decode 전에 검사한다. envelope에서 추출한 payload와
  각 migration 반환값을 검사한 뒤 다음 단계로 넘긴다. encode/save도 대응 한도를 검사해
  스스로 읽을 수 없는 새 파일을 무심코 덮어쓰지 않도록 한다.
- codec 한도 오류는 `RouterSnapshotError`의 typed case로 표현하고, 기존 `.use` recovery의
  명시적 실패 처리 경로로 전달한다. 파일 읽기 제한 오류는 storage 실패로 구분하며
  codec recovery를 암묵적으로 호출하지 않는다. 메시지에 payload를 넣지 않는다.

보장 범위: 호출자가 이미 만든 `Data`의 선행 할당이나 앱의 migration/Decodable 내부
메모리 할당까지 통제하지 않는다. payload 검사는 envelope 해독 후 route 구조 decode 전에
적용된다. 전체 입력 한도가 envelope/Base64 해독의 입력 규모를 먼저 제한한다.

대상: `RouterByteStore.swift`, `RouterSnapshotStorage.swift`, `RouterSnapshot.swift`, 관련
snapshot/driver/partial 테스트, external consumer, README/DocC/예제, public API baseline.

**종료 조건:** RXP-AC-201~203 통과. 정상/초과 입력의 decoder 호출 여부와 파일·state·revision을
검증하고, API 호환성·문서를 반영한 독립 커밋으로 고정한다.

### 3단계 — 자동 복원 driver에 부분 복원 연결

**선택:** 새 driver를 만들지 않고 기존 driver에 validator를 받는 opt-in initializer를 추가한다.
원본을 먼저 restore하고 나중에 정리하거나, 외부에서 public `restorePartially`를 호출한 뒤
기존 driver를 활성화해 원본 파일을 다시 적용하는 이중 흐름은 만들지 않는다.

- 새 overload는 `validator:`를 필수로 받고, `validationTimeout`과 선택적 `tabTopology`를
  받는다. 기존 두 initializer와 activation 반환형은 보존한다.
- 첫 구현의 partial initializer는 `recovery:`를 받지 않는다. 현재 직접 partial restore처럼
  decode/migration 실패를 오류로 반환한다. 기존 exact driver의 `.use` fallback 의미를
  validator로 재해석하지 않는다. partial+recovery 정책의 별도 결합은 후속 범위다.
- 이미 존재하는 `preparePartialRestoration`을 재사용한다. direct/driver가 공유하는 내부
  진입점에서 starting revision, transition ID, request-root ID, execution precondition을
  전달하도록 정리한다. driver의 stop/generation 보호를 잃는 public helper 단순 호출은 금지한다.
- 순서: **2단계 입력 제한 → decode/migration → 명시 topology 보정 → route validator →
  상태 검증·정책 → 한 번의 apply → 정상 저장 경로**.
- `lastPartialRestoration` 같은 optional observable outcome을 추가하는 안을 우선한다.
  기존 `lastActivation.restored`와 decode provenance는 유지한다. outcome은 해당 시도의
  후보 보고와 반환 시점 transition이며, deferral의 최종 결정을 실시간 추적하는 값은 아니다.
- 새 시도 시작/noSnapshot/실패 시 report 수명을 명확히 정한다. `alreadyActive`는 유효한
  현재 시도의 보고를 유지하며, 종료된 generation의 결과는 새 시도의 값을 덮지 못한다.
- accepted partial 결과는 기존 coalescing 저장 경로로 보낸다. 보정 결과가 현재 상태와 같아
  unchanged여도 오래된 파일의 무효 route가 남지 않도록 저장한다. applied의 기존 observer
  저장과 중복 예약을 정리하고, deferral도 terminal 수락 시점과 연결한다.
- rejected/cancelled/stale 후보는 저장하지 않는다. 그 사이 발생한 앱의 별도 정상 navigation
  저장은 계속 유효하다. 저장 실패 시 파일 오류를 표시하고 이후 명시적 save 재시도를 허용한다.

대상: `RouterStateRestoration.swift`, `RouterRestorationDriverTypes.swift`,
`RouterPartialRestoration.swift`, `RouterStore+Snapshot.swift`, `RouterTestStore.swift`,
`TabRestorationExample.swift`, driver 생명주기/partial/consumer 테스트와 sanitizer 필터.

**종료 조건:** RXP-AC-301~304 통과. 대기·취소·재시작은 bounded barrier로 증명하고,
검증된 파일의 재실행까지 확인한 후 독립 커밋으로 고정한다.

### 4단계 — 선택적인 명시적 탭 ID

**선택:** 기존 macro 선언을 보존하고 `id:`가 필수인 추가 overload로 명시 ID를 선택하게 한다.
기존 case-name 기본값은 유지하며 alias 추정이나 저장된 ID 자동 이름 변경은 하지 않는다.

- 사용 모양: `@TabItem("Settings", systemImage: "gearshape", id: "settings")`.
  새 overload도 selected image/role의 기존 옵션을 지원한다.
- `Tab.rawValue`는 case 이름을 유지하고 `routerScopeID`만 지정한 영속 ID를 반환한다.
  SwiftUI의 `id: Self`와 route Codable 이름을 동시에 바꾸지 않는다.
- parser·분석 모델·생성기·진단을 함께 변경한다. ID는 정적 문자열 literal만 받는다.
  빈/공백-only/보간/동적 표현식을 거절하며 유효한 ID를 임의 trim/소문자화하지 않는다.
- effective ID는 명시 ID 또는 기본 case 이름이다. 문자열 escape를 해석한 값으로 enum
  전체 중복을 검사하고 문제가 있는 `@TabItem` 위치에 진단을 붙인다.
- typed select/badge, host catalog, scope projection, topology, 기본 link plan이 실제
  `routerScopeID`를 사용하는지 대조한다. case 이름을 직접 scope로 만드는 경로는 수정한다.
- 예제는 먼저 기존 scope ID를 명시적으로 고정하고 이후 case 이름을 바꾸는 순서를 보여준다.
  처음부터 다른 ID를 지정하면 기존 branch가 자동 rename되는 것이 아니라는 점을 설명한다.
- **route enum case 자체가 snapshot payload에 인코딩돼 있다면 별도 Codable/schema
  migration이 필요하다.** 명시적 탭 ID가 그 migration까지 대신한다고 주장하지 않는다.

대상: `Macros.swift`, `RouterTabExpansion.swift`, `TabItemMacro.swift`, 관련 macro 진단,
macro expansion/behavior tests, host/topology/URL/consumer 테스트, 예제·DocC·API baseline.

**종료 조건:** RXP-AC-401~403 통과. 기존 source fixture의 expansion 유지와
이전 선언→새 선언 간 실제 JSON 복원을 모두 증명한 후 독립 커밋으로 고정한다.

### 5단계 — 빌드 캐시·중복 빌드 개선과 전후 측정

**선택:** 2~4단계가 끝난 동일 제품 소스에서 CI 개선 효과를 측정한다.
현재 `c0d3a40f`의 실행 시간과 기능을 추가한 미래 소스의 시간을 바로 비교하지 않는다.

1. RXP-T501: 4단계 완료 SHA를 기준으로 현 설정 반복 실행 3회의 job/step 시간을 수집한다.
   queue, toolchain/setup, dependency resolve, compile, test/DocC, artifact 시간을 분리한다.
   새로운 계측이 필요하면 먼저 계측만 추가한 설정으로 기준값을 만든다.
2. RXP-T502: 의존성 다운로드 캐시부터 적용한다. compiled artifact 캐시는 별도 계층으로
   검토하며 runner OS/arch, Xcode build·Swift/SDK fingerprint, manifest와 resolved hash,
   product-source digest, destination, configuration, coverage/sanitizer/compiler flags,
   cache format version을 key에 반영한다. source 변경은 실제 재빌드를 요구한다.
3. RXP-T503: 동일 job·동일 source/SDK/flags의 중복 compile 또는 symbol-graph 작업을
   계측 후 공유한다. standalone `principle-gates.sh`는 계속 모든 검사를 수행한다.
   cross-workflow 산출물 공유는 SHA·환경·생성 옵션 manifest 검증 없이 도입하지 않는다.
   preview와 release DocC를 같은 결과로 간주하지 않는다.
4. RXP-T504: 제품 source digest가 같은 후보에서 cache miss 1회와 hit 3회를 측정한다.
   baseline 중앙값과 warm 중앙값, cold 비용, 전체 wall time과 runner 사용 시간을 보고한다.
   warm build 중앙값 20% 단축은 목표이며 결과가 그에 못 미치면 그대로 명시한다.

캐시 경계:

- debug/release, coverage, ASan, TSan, simulator/Catalyst/host의 산출물을 섞지 않는다.
- `external-consumer-smoke.sh`의 local positive consumer는 과거 stale dependency 링크를
  막기 위해 매번 새 scratch를 만든다. 이 격리를 캐시 최적화 명목으로 제거하지 않는다.
  negative fixture의 의도된 컴파일 실패도 별도 scratch/검사로 유지한다.
- repository 전체 `.build`를 단일 cache로 저장하지 않는다. gh-pages, xcresult, 검증 결과,
  외부 consumer 격리 scratch를 무차별 재사용하지 않는다.
- cache hit는 검증 통과가 아니다. 테스트·baseline 비교·문서 검사 등 gate는 실제 실행한다.
- release는 exact tag SHA에서 필수 gate를 실행한다. 권한 없는 PR의 compiled cache를
  release의 신뢰 가능한 산출물로 사용하지 않는다. cache save 권한과 fork 경로를 검사한다.
- cache miss/손상 시 재빌드 fallback과 수동 cache 우회를 제공한다. 시간 단축을 위해
  timeout·coverage 기준을 완화하거나 platform job을 skip하지 않는다.

대상: `.github/workflows/{principle-gates,docs-ci,coverage,performance-smoke,sanitizers,platforms,release,migration-smoke}.yml`,
필요한 공통 cache/계측 helper, DocC/API 빌드 script의 측정된 중복 지점.
새 외부 Action은 구현 시 공식 문서·릴리스를 확인하고 저장소 규칙대로 전체 commit SHA로 고정한다.

**종료 조건:** RXP-AC-501~504 검증 결과와 측정 보고서 작성.
캐시가 제대로 재사용된다는 기능 증거와 실제 시간 개선 성과를 구분해서 판정한다.

## 4. 작업 순서와 단계 종료 규칙

| 순서 | 작업 ID | 산출물 | 다음 단계로 넘어가는 조건 |
| --- | --- | --- | --- |
| 2-1 | RXP-T201 | 유한 파일 저장소 API·제한 읽기·오류 | AC-201 충족 |
| 2-2 | RXP-T202 | codec envelope/payload/migration 한도 | AC-202 충족 |
| 2-3 | RXP-T203 | direct/driver/partial 통합·호환성·문서·API diff | AC-203 및 단계 gate 통과 |
| 3-1 | RXP-T301 | 공통 부분 복원 진입점·driver opt-in API | AC-301 충족 |
| 3-2 | RXP-T302 | generation/취소/deferral·보고서 수명 | AC-302~303 충족 |
| 3-3 | RXP-T303 | 저장·재실행·실패 처리 예제/소비자 | AC-304 및 단계 gate 통과 |
| 4-1 | RXP-T401 | ID macro overload·분석/생성/진단 | AC-401~402 충족 |
| 4-2 | RXP-T402 | rename fixture·host/link/복원 통합·문서 | AC-403 및 단계 gate 통과 |
| 5-1 | RXP-T501 | 동일 제품 소스의 기준 시간·실행 inventory | AC-501 기준 데이터 확보 |
| 5-2 | RXP-T502 | 계층별 캐시·무효화·권한·우회 | AC-502 충족 |
| 5-3 | RXP-T503 | 계측된 중복 작업 정리 | AC-503 충족 |
| 5-4 | RXP-T504 | cold/warm 비교·최종 gate 보고 | AC-504 결과와 목표 달성 여부 명시 |
| 마무리 | RXP-T601 | 전체 통합 검증·재검토·commit/push·정확한 SHA CI | 아래 최종 gate 통과 |

표의 AC 약칭은 `RXP-AC-*`다. 단계별 제품 변경과 검증을 묶어 독립 커밋으로 남긴다.
2단계가 끝나기 전에 3단계를, 3단계가 끝나기 전에 4단계를 구현하지 않는다.
작업이 승인되어 시작되면 범위 안의 단계 전환마다 사용자 재승인을 요구하지 않는다.
호환성 위반이나 범위 확대가 필요할 때만 그 변경을 별도로 제시한다.

### 단계 gate

- 추가 동작을 고정하는 반례/정상 대조군 → 구현 → focused 회귀.
- `swift test --jobs 2 --no-parallel` 및 해당 단계 macro/consumer/script 검사.
- API baseline은 실제 변경을 검토한 뒤 갱신한다. 예산은 필요한 추가분과 근거를 명시한다.
- README 양 언어·DocC·예제·CHANGELOG와 API 일치를 확인한다.
- 실패하면 같은 단계에서 원인을 해결한다. 기존 assertion을 약화하거나 skip으로 통과시키지 않는다.
- 전체 플랫폼/DocC 빌드를 매 작은 수정마다 반복하지 않고 단계의 최종 후보와 마지막 통합
  후보에서 실행한다. 새 변경/실패/우려가 없으면 동일 검사를 불필요하게 반복하지 않는다.

### 최종 gate

- `principle-gates.sh --platforms=all`, 외부 macro consumer, API·DocC·lint, coverage·성능,
  ASan·TSan과 지원 플랫폼 runtime CI를 정확한 최종 커밋에서 확인한다.
- 새 입력 제한/driver 부분 복원/명시 ID 시나리오가 sanitizer 필터와 consumer에서
  **실제로 실행**됐는지 확인한다. 기존 통과 개수만 인용하지 않는다.
- 모든 RXP-FR/AC → 작업 → 테스트·실행 증거를 대조한다. 통과·실패·미실행을 구분한다.
- 로컬·origin/main·원격 SHA와 dirty 상태를 확인한다. 구현 검증 완료와 실제 6.1 발행은 분리한다.

## 5. 반례 점검과 남은 설계 확정 지점

구현 착수 시 API spike에서 아래를 확인하고 결정 이력을 추가한다. 이 문서의 타입·인자
이름은 제안이며 공개 baseline에 올리기 전에 외부 호출 예제로 확정한다.

| 반례 / 결정 | 계획이 요구하는 처리 |
| --- | --- |
| 파일 size만 확인하고 나중에 전체 읽기 | 실제 읽기 상한으로 방지. metadata만으로 완료 판정 금지 |
| 작은 envelope의 migration이 거대한 payload를 반환 | 매 반환값 검사, 후속 decode 미호출. closure 내부 할당까지 막았다고 주장하지 않음 |
| 실패한 partial 후보를 먼저 적용하고 나중에 되돌리기 | apply 이전에 계획 완료. 중간 commit 0회 |
| validator가 무시한 취소 뒤 old driver가 commit/report 갱신 | revision + generation + request family의 종료 전 검사와 소유권 검증 |
| unchanged가 발생해 정리 전 파일이 계속 남기 | 새 partial 모드의 accepted 정상화 저장 및 재실행 fixture |
| report가 있으면 복원 성공으로 표시 | report와 transition/저장 status를 분리 |
| 명시 ID가 다른 탭의 암묵 ID와 충돌 | effective ID 전체를 대상으로 컴파일 진단 |
| scope ID 고정만으로 모든 enum case rename이 호환된다고 안내 | scope rename fixture와 route payload migration 경계를 별도로 설명 |
| 서로 다른 소스/SDK의 cached module 또는 test 성공 로그 재사용 | key/manifest·실제 재빌드·실제 gate 실행으로 차단 |
| queue 감소만으로 build가 빨라졌다고 주장 | queue와 실행 시간을 분리하고 반복 중앙값으로 판정 |

계획에서 의도적으로 정하지 않은 값은 앱별 유한 입력 한도와 실제 cache 성능 개선율이다.
입력 크기는 호출자가 설정하며 예제 숫자는 예시로 표시한다. 성능 개선율은 5단계 측정으로
확정한다. 기존 호환성을 깨는 전역 기본 한도나 성공하지 않은 cache 최적화를 임의로
확정한 상태로 구현·배포하지 않는다.

## 6. 후속 재검토와 개선 계획 — 2026-09-21 추가

`b82b2a81ec241ed21e620741ed5aa8892800f189` 재검토에서 원격 CI 7개와 집중 테스트 66개는
통과했지만, 별도 소비자 재현으로 복원 실패 뒤 자동 저장의 원본 덮어쓰기(F1)와
migration 오류 계약 변경(F2)을 확인했다. 앞의 실행 기록은 당시의 검증 이력으로 보존하며,
그 통과 기록만으로 6.1.0 발행 가능 또는 모든 AC의 완전한 충족을 주장하지 않는다.

[배포 전 후속 개선 계획](2026-09-21-release-readiness-remediation-plan.ko.md)에 다음 작업을 추가했다.

- [x] RRR-T701: RXP-203/302~304 — 자동 생명주기 저장 보호 및 F1 회귀.
- [x] RRR-T702: RXP-202/공통 호환성 — migration 오류 계약 복구 및 F2 회귀.
- [x] RRR-T703: RXP-201/301~304/402 — 실제 파일·mounted host·validator·ID 진단 검증 공백 보강.
- [ ] RRR-T704: RXP-503 — 실제 required CI 검사와 repository ruleset 연결.
- [ ] RRR-T705: RXP-501~504 — 세부 계측과 동일 조건 반복 비교, 근거 있는 최적화만 유지.
- [ ] RRR-T706: 전체 — 최종 SHA 검증·commit/push·재검토 및 6.1.0 발행 준비 상태 판정.

후속 문서는 Draft이며 이번 요청에서는 계획만 작성했다. 실제 구현·운영 설정·발행은 수행하지 않았다.
