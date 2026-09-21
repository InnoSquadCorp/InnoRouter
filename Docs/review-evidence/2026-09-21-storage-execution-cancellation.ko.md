# 저장 실행 경계의 취소 수정과 검증

기준 소스: `14e81a7f5f8a55a9e356f4c2930f3f43bdd3d4d4`.
연결: RRR-T707~709, RRR-AC-01~03/05~08. 실제 6.1.0 발행은 이번 범위 밖이다.

## 문제와 수정

기존 자동 저장은 MainActor에서 generation/epoch를 확인한 뒤 storage actor 호출을 기다렸다.
storage가 느린 load를 처리하는 동안 driver를 중단해도 이미 actor에 도달한 save가 나중에 실행되어
새 driver가 같은 파일에 저장한 최신 상태를 덮어썼다. 기존 catch/순서 검사만으로는 막지 못했다.

자동/scene flush의 durability ticket을 취소 가능한 것으로 표시했다. stop, 마지막 detach,
새 저장 또는 삭제는 미시작 ticket을 동기적으로 무효화한다. storage actor는 실제 동기 I/O를
호출하기 직전에 Mutex 아래에서 유효한 ticket을 확보한다. 무효화와 실행 시작 중 먼저 일어난
동작이 결과를 결정하며 I/O 동안 lock을 유지하지 않는다. 명시 save는 취소 가능한 ticket이 아니므로
stop/caller 취소 뒤에도 수락한 저장을 마친다. 이미 시작된 I/O를 강제로 rollback한다는 보장은 없다.

## 직접 회귀 증거

새 `RouterRestorationStorageCancellationTests`는 시간 지연 추측 대신 enqueue/finish 신호를 사용한다.
load가 실제 파일을 읽은 뒤 storage actor를 점유하고, save가 해당 actor 호출 경계에 도달한 것을
확인한 다음 중단/교체를 실행한다. save 종료를 확인한 후 최신 파일 bytes를 직접 비교한다.

| 경로 | 수정 전 | 수정 후 |
| --- | --- | --- |
| automatic/scene flush × stop/마지막 detach 네 조합 | 이전 write 1회, 최신 파일 손실; 8개 assertion 실패 | 이전 write 0회, 최신 bytes 보존 |
| 명시 save + stop + caller 취소 | 정상 저장 | 정상 저장 유지 |
| 새 navigation/명시 save가 이전 자동 저장을 대체 | 후속 검증 추가 | 최신 저장만 1회 |
| 삭제가 이전 자동 저장을 대체 | 후속 검증 추가 | 쓰기 0회, 파일 없음 |

mounted `RestorationLifetimeTests.backgroundAfterRestoreFailure`도 실제 파일을 사용하며,
scene flush의 완료 신호를 기다려 실패 status와 원본 bytes를 확인한다. 즉시 참인 조건과
한 번의 main queue drain을 음성 assertion의 완료 근거로 쓰던 방식을 제거했다.

로컬 전체: **695 tests / 88 suites 통과**, 기존 테스트 도구의 의도된 known issue 1건.
새 3개 테스트 함수는 총 8개 case를 실행했다. 같은 suite를 ASan/TSan 필터에 추가했다.
공개 API 추가 없이 내부 ticket·executor와 package-only 검증 신호를 변경했다.

`./scripts/principle-gates.sh` 전체가 통과했다. DocC, 공개 API baseline, 문서·예제,
외부 consumer, 생성 시나리오와 의도된 실패 probe를 포함한다. 새 취소 suite는
Address Sanitizer와 Thread Sanitizer에서도 각각 8개 case를 실행해 통과했다.

## iOS 18.6 실행 증거

전용 iPhone 16 Pro simulator, iOS 18.6 (22G86), Xcode 27.0 / Swift 6.4에서 실행했다.
이 결과는 iOS 18.0나 모든 OS 하한의 실행 증거가 아니다.

- `NativeSceneSmoke/Restoration`의 별도 앱은 공개 `@Router`, `RouterHost`, restoration modifier를 사용한다.
- `--seed` 실행에서 상세 route를 commit하고 `READY_FOR_BACKGROUND`를 확인했다. 이때 저장 파일은 없었다.
- debounce는 1시간이다. Settings를 실행해 실제 앱을 background로 보낸 뒤 `SAVED` marker로 파일 저장 완료를 확인했다.
- 첫 프로세스 PID 35954를 종료하고 인자 없이 재실행했다. 새 PID 37745에서
  `PASS restored detail after process restart`를 확인했다.
- 같은 simulator에서 전체 `InnoRouterPlatformTests` 실행: **12 tests 통과**, 동적 인자 포함 실행 13회,
  실패/skip 0. result bundle은 `.build/restoration-host-ios18.xcresult`다.

probe 생성·실행 방법은 [probe 안내](../../NativeSceneSmoke/Restoration/README.md)에 있다.
생성된 Xcode project와 빌드 결과는 버전 관리하지 않는다.

## 완료 기준과 남은 검증의 구분

- 이번 결함의 파일 보존, 취소/교체, 명시적 저장 및 실제 iOS 18.6 재시작은 직접 검증했다.
- 원격 최종 SHA의 required 검사 결과는 PR/현재 작업의 완료 보고와 연결한다. 로컬 성공으로
  remote CI나 실제 Release 발행 완료를 대신하지 않는다.
- 이전 계획의 모든 load/decode/validator/policy 조합을 새로 실행했다고 주장하지 않는다.
  기존 회귀와 이번 추가 테스트가 실제로 검사하는 경계만 완료 증거로 사용한다.
- main ruleset 19074564의 strict required GitHub Actions context 24개 및 bypass 없음은 재확인했다.
- 기존 696초/587초와 과거 712초의 차이는 소스가 다른 비교다. 9.9% 개선 주장을 철회했다.
  동일 소스 baseline/후보 3회 이상 비교는 여전히 별도 미완료 실험이며 이번 변경은 CI 성능 최적화를 추가하지 않는다.
