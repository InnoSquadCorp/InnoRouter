# Native 병렬 step / 변경 영향 CI 준비

7.0.0 릴리즈 이후 main 기준 CI 개선 PR이다. ruleset/변수와 릴리즈 코드·태그는 변경하지 않는다.

## 적용되는 범위

- 기존 `CI Plan`과 항상 실행되는 `CI Required` 이름 및 의존성 인벤토리를 유지한다
- 순수 문서/FUNDING PR만 빌드 없는 Ubuntu 정적 policy 검사로 줄인다
- 정확한 PR base/head의 merge-base diff에서 일반 100644 파일을 읽는다
- README/README.ko/CONTRIBUTING과 일반 docs Markdown만 허용한다
- 모든 fenced block 내용을 비교한다. 코드 fence 언어·본문·삭제, indented/inline code, HTML, DocC directive, front matter 수정은 문서 경량 증명이 아니다
- Sources/Tests/Examples/consumer/Package/workflow/generator/plugin/unknown 경로와 release metadata는 경량 증명 대상이 아니다
- diff/UTF-8/파일 모드/파서 검증에 실패하거나 diff가 비면 모든 기존 CI 검증을 선택한다
- release-validation/Dependabot, main/develop push, merge queue, workflow_dispatch는 기존 전체 검증이다
- aggregate는 계획한 success/skipped만 허용한다. 경량 증명의 base/head와 실제 Git 내용을 다시 읽어 검증한다
- policy의 독립 read-only Python 검사만 native `parallel`로 묶는다. compiler, SwiftPM `.build`, Xcode DerivedData, codegen, 캐시 쓰기, simulator는 병렬 공유하지 않는다
- actionlint 1.7.12는 native group을 검증한 후 lint용 임시 serial projection만 읽는다. 원본 workflow는 native YAML이며 광범위한 ignore를 추가하지 않는다

## product/target 변경 영향 준비

`scripts/ci-product-graph.json`은 Package.swift SHA-256에 묶인 검토용 그래프다.
`scripts/ci-product-impact.py --base <40자리 SHA> --head <40자리 SHA>`는 다음을 출력한다.

1. 변경 target 및 역의존 target/product/test
2. 선택 test 자체의 의존성 closure와 거기에 포함되는 product
3. 영향받는 외부 consumer/sample 패키지
4. 서로 다른 scratch-path를 사용하는 native `swift build --target` 명령 초안

이 도구에는 실행, manifest pruning, workflow 조건 변경 기능이 없다. 현재 필수 테스트/플랫폼/릴리즈 검증을 생략하지 않는다.
`swift test --filter`는 테스트 실행 필터일 뿐 전체 테스트 빌드 범위를 줄였다는 증거가 아니다.
일반 테스트 명령은 `--no-parallel`인 전체 패키지 테스트로 명시한다.

실제 Apple toolchain에서 `swift package dump-package`를 별도 파일로 보관한 뒤
`--verify-dump <파일>`로 target/product/local dependency/input inventory를 대조할 수 있다.
이 VM에는 Swift/Xcode가 없어 실제 dump/build/test 및 native GitHub 실행은 미검증이다.

## 단계별 검증 및 활성화

1. 로컬 policy/negative tests와 pinned actionlint를 모두 확인한다. Ruby가 없는 VM에서는 Ruby/Psych 기반 기존 guard를 검증한 것으로 간주하지 않는다
2. 별도 승인 후 비보호 검증 PR에서 prose-only, executable docs, source, mixed, unknown, diff 실패 시나리오의 실제 job 결과를 확인한다
3. GitHub의 native parallel 자식 step REST 표현과 기존 provenance/Dependabot verifier의 이름 인벤토리가 일치하는지 확인한다
4. Apple CI에서 정확한 후보 SHA의 전체 원래 검증과 target별 진단 결과를 비교한다. package graph, resources, macro host 조건, test discovery/count, fixtures, consumer가 빠지지 않아야 한다
5. selective tests를 활성화하려면 target 분리와 명령 지원까지 별도 검증한다. 이 변경만으로 전체 test compilation 생략이 활성화되었다고 주장하지 않는다
6. 배포는 기존 exact-SHA clean full release evidence/gate를 그대로 사용한다. 문서/선택 CI의 녹색 결과는 릴리즈 증거가 아니다

## Router aggregate 전환

Router는 기존 `INNOROUTER_CI_AGGREGATE` rollout 모드와 legacy bridge를 유지한다.
비활성 상태에서는 기존 독립 legacy workflow가 계속 전체 실행되므로 문서 경량 CI 비용 감소가 아직 실현되지 않는다.
변수/ruleset을 이번 준비 과정에서 변경하지 않는다. 실제 전환에는 별도 승인과 기존
`scripts/rollout-ci-aggregate.py`의 현행 순서를 사용하고, 먼저 CI Required의 전체/선택/실패/취소/예기치 않은 skip 동작을 확인한다.

## 실행 가능한 opt-in workflow 연결

`scripts/ci_product_execution.py`를 기존 platforms build-matrix의 두 consumer step에 연결했다.
`INNOROUTER_CI_AGGREGATE=true`와 `INNOROUTER_PRODUCT_CI=true`가 모두 설정된 ordinary PR만 선택한다.
어떤 variable/설정도 이번 작업에서 변경하지 않았다.

SwiftPM dump-package와 정확한 PR base/head·candidate·manifest/graph를 확인한 뒤 실제 reverse-dependency closure로
consumer target 영향을 판단한다. Inspector만 바뀌면 umbrella-only MacroFirstSmoke는 검증된 skip이 가능하고,
Inspector/Testing을 포함하는 DeveloperToolsSmoke와 그 뒤의 public-interface 검증은 계속 실행한다.
각 step은 exact-SHA·선택·명령·결과 receipt를 생성하고 다시 검증한다. 실패/누락/위조/다른 후보의 receipt는 통과하지 못한다.
모든 platform matrix 행과 실제 runtime test gate는 유지한다. 공유/불명확한 변경, bot/release/main/queue/manual lane,
비활성 rollout은 기존 full consumer 명령을 그대로 실행한다.

이 코드는 실제 workflow 연결과 실행 adapter까지 준비했지만, 이 VM에는 Swift/Xcode가 없으므로
실제 Apple consumer build와 SwiftPM graph 해석은 이후 승인된 검증이 필요하다.

## 이 PR의 권한 및 검증 경계

Merged PR cleanup workflow는 항상 read-only dry run이다. actions:write job은 포함하지 않는다. 실제 취소 기능 활성화는 별도 승인된 workflow 변경이 필요하다.
DI/Network의 default-on 설정을 Router에 전파하지 않는다. product scope와 job cancellation은 명시 opt-in이고 aggregate 전환은 required-check migration과 함께 별도 승인한다.
DocC catalog는 prose-only 대상이 아니므로 symbol/article link 검증을 유지한다. Router consumer 선택은 validated target reverse-dependency closure에 기반하며 매크로 변경은 full fallback한다. temporary path는 recipe에서 resolve하여 macOS symlink 경로를 일치시킨다.

검증: Python/Ruby policy 및 negative tests 190개, pinned actionlint 1.7.12와 native parallel schema 12 workflows, public operations/reusable concurrency/CI optimization 계약 통과. Apple compile/runtime 검증은 이 PR hosted CI 결과로 별도 확인한다.
