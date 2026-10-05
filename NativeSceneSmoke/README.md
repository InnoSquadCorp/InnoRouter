# Native scene consumer probe

This independent macro-first application imports only `InnoRouter`. It is not
a fourth published library product. Run from a logged-in macOS GUI session:

```sh
./NativeSceneSmoke/script/build_and_run.sh
```

The script builds a real `.app` bundle and opens it through Launch Services.
For each of allow, reject, and cancellation, it opens a value-based SwiftUI
window, calls the real `NSWindow.performClose` path, waits for a policy deferral
and native reopening, and verifies canonical/native state after resolving it.
It closes its own windows and exits, retaining separate stdout/stderr evidence
under `.build/native-scene.*`. Missing success markers and timeouts fail the
script; an already-running probe is preserved rather than killed.

## iPadOS and visionOS

The Xcode project provides separate iPadOS window and visionOS immersive-space
consumer apps. Select a dedicated, already booted simulator explicitly:

```sh
./NativeSceneSmoke/script/run_simulator.sh ipad <simulator-uuid>
./NativeSceneSmoke/script/run_simulator.sh vision <simulator-uuid>
```

The iPad app closes its real `UIWindowScene` through session destruction. Its
manifest supports all four orientations so iPad multitasking can create the
second scene. The visionOS app invokes the real `dismissImmersiveSpace` action.
Both verify policy deferral, native reopening, allow/reject/cancel outcomes,
and canonical state. The visionOS fixture waits for the driver's asynchronous
opening completion before requesting a native close, and for dismissal
completion before starting the next independent scenario. View appearance or
disappearance alone is not that completion signal. Passing `--rapid-reopen`
directly to the visionOS app additionally exercises back-to-back scenarios.

The script redirects app stdout/stderr to unique simulator files, waits for
the launched process to exit, and copies the evidence before uninstall or
simulator shutdown can clear it. It requires the final PASS marker; the exit
status of `simctl launch` alone does not prove a successful probe. A missing
marker also collects this app's system logs and recent crash reports. It does
not boot, erase, shut down, or change settings on the selected simulator, nor
stop an already running probe.

These probes exercise native scene effects through real app lifecycles. They
do not prove user gesture/VoiceOver usability or physical-device acceptance.

## Inspector simulator consumer

The separate `RouterInspectorProbe` target imports the runtime, Inspector, and
Testing products to exercise the optional developer UI and scenario adapter.
Its macro enables `inspectorCatalog: true`, so preview uses the generated
catalog rather than an empty fallback. This fixture is not a published product.

```sh
bash ./NativeSceneSmoke/script/open_inspector_simulator.sh <booted-iOS-simulator-uuid>
```

The same source supports the existing macOS `open_inspector.sh` fixture. The
iOS target supports iPhone and iPad, with visible revision/policy counters,
a cancellable execution hold, and a redacted-export check. The hold expires
after five minutes to bound an abandoned probe. Launch success is not a UI
verification result: inspect the hierarchy and screenshots after preview,
execute, cancel, recording controls, timeline filtering, and export actions.
The script neither boots a simulator nor changes its settings and refuses to
replace an already-running probe.

The target is intentionally simulator-only. Its developer runtime search paths
use the selected Xcode platform's `Testing.framework` and `lib_TestingInterop`,
because the scenario adapter imports `InnoRouterTesting`. These paths are not
appropriate for a shipping application.

For repeatable control interaction and screenshot/hierarchy evidence:

```sh
xcodebuild test -project NativeSceneSmoke/NativeSceneSmoke.xcodeproj \
  -scheme RouterInspectorProbe -destination 'platform=iOS Simulator,id=<simulator-uuid>' \
  -derivedDataPath NativeSceneSmoke/.build/derived-inspector \
  -parallel-testing-enabled NO -resultBundlePath <new-result-bundle-path> \
  CODE_SIGNING_ALLOWED=NO
```

`RouterInspectorUITests` uses app-local English language arguments, not simulator
settings. Its assertions await every state change through a predicate instead
of reading it once, report a timeout at the calling line with the awaited and
observed state, and retain screenshots and accessibility hierarchies in the
result bundle. Only its own launched probe is terminated during test cleanup.

Three localization scenarios launch the same fixture with
`--localization-probe`, exposing app-local English/Korean/German/Arabic
switches. Each starts from a fresh launch, so one failure costs one scenario:

- `testInspectorLocaleRelocalizesHeldExecutionWithoutRemounting` changes locale
  and layout direction without remounting the Inspector, checks translated
  execution and cancellation, and preserves the entered URL and execution
  status from Arabic to English and back. Direction changes during a held
  execution must retain the pending task, without an extra policy submission or
  an implicit cancellation.
- `testInspectorLocaleRelocalizesRecordingControlsWithoutRemounting` checks
  translated recording controls and statuses, and retains screenshots and
  hierarchies for right-to-left and narrow-sidebar review.
- `testInspectorDirectionChangePreservesSelectionAndRecording` preserves the
  selected event and the in-progress recording from Arabic to English and back.

These switches exist only in the probe and do not alter simulator settings.
`testInspectorPolicyPreparationAcknowledgesRequestedState` checks the fixture's
explicit Hold/Resume commands and visible state acknowledgement, including
repeating Hold without toggling it off. It then proves that the real Inspector
execution is held, cancelled without a commit, and applied after Resume.
These setup controls replace the nested native switch that once ignored a tap
on CI. No test retries, longer timeouts, or Inspector assertions were removed.

### Inspector execution diagnostics

The five Inspector scenarios opt in to Debug-only diagnostics through the
app launch environment `INNOROUTER_INSPECTOR_TRACE=1`. This does not enable
tracing in Release or change any wait, input, or success condition. Each process
emits at most 256 `INSPECTOR_EXECUTION` lines and 256 `INSPECTOR_PROBE` lines;
the last permitted line is `event=trace.limit`. No URL, route payload, or policy
message is recorded. Output is synchronous and opt-in, so an instrumented pass
does not prove a timing-sensitive failure has been repaired.

`INSPECTOR_EXECUTION` records the private Execute action, task creation/entry,
the resolved request immediately before store submission, store return, task
exit/status, Cancel, and view appearance/disappearance. The `run` identifier
correlates task events; `run=0` denotes a view or Cancel event. `INSPECTOR_PROBE`
records Hold/Resume, policy entry/return with canonical counters, and the counter
string observed by the SwiftUI view. That observation is not proof of compositor
or accessibility delivery. A failed predicate also retains a `wait-timeout`
screenshot and full accessibility hierarchy before reporting the original
assertion; it does not retry the predicate or the input.

The existing `platforms` workflow's `test Inspector UI (iPadOS)` job captures
these lines in `InspectorUI.xcresult`, already included in the
`inspector-ui-evidence` artifact on both success and failure. On the new exact
PR head, download that artifact and run:

```sh
xcrun xcresulttool export diagnostics --path InspectorUI.xcresult \
  --output-path inspector-diagnostics
rg 'INSPECTOR_(EXECUTION|PROBE)' inspector-diagnostics \
  -g 'StandardOutputAndStandardError-com.innosquad.router.inspector-probe.txt'
xcrun xcresulttool export attachments --path InspectorUI.xcresult \
  --test-id 'InspectorUITests/testInspectorDirectionChangePreservesSelectionAndRecording()' \
  --output-path inspector-attachments
```

Read the failing process's `pid` and event sequence together with the XCTest
tap activity. After a `view.appear` marker and before either trace limit, an
absent `execute.action` separates action non-entry from later stages. An action
without `task.enter` points to the task boundary; `store.submit` without
`policy.enter` narrows it to submission/policy entry. A `policy.enter policy=1`
with a stale `counters.view-value` narrows the model/view observation boundary;
an updated view value with a stale failure hierarchy narrows the remaining
display/accessibility boundary. Cancellation, disappearance, invalid input,
and unresolved routes have explicit markers. Missing or truncated diagnostics
are inconclusive. Rerunning the old immutable `681ef1cf` CI run cannot produce
these new markers; the ordinary push's new head must run the existing job.

In 6.1.1 the former single localization test became the three scenarios
above, and its one-time reads became predicate waits with the same timeouts. No
retry was added and no Inspector assertion was removed.

The CI gate requires all five current Inspector UI test names to pass without skips;
a passing count from an older test bundle does not satisfy the gate. When a test
fails, the job prints every assertion the result bundle recorded.

## Native scene isolation

The simulator runner reinstalls only its disposable visionOS probe to clear
persisted scene sessions before each allow/reject/cancel case. It checks every
case's success marker and fails on the first error.
It does not retry a failed case. Launching the vision probe directly without
`--resolution` retains the combined sequence for stress testing; `--rapid-reopen`
also removes the final driver-dismissal wait.

Rapidly reusing a scene in one process can return `scene invalidated before
create completion` on Xcode 27.0 with visionOS 26.5. The same error was reproduced
in a separate SwiftUI-only application. Isolation keeps independent policy
cases from inheriting that scene session; it does not claim to fix that system
behavior. Process restart alone did not consistently isolate the sessions;
three complete sets passed after clearing the probe's installation state.
Pinned CI also exposed incomplete `simctl --console` output even when the
system recorded a voluntary process exit. Direct file output and process
tracking preserve the evidence without relaxing the success-marker checks.
The pinned CI platform jobs also execute the iPadOS and visionOS
native probes and retain their logs separately from platform unit tests.

## Catalyst platform test host

`RouterCatalystPlatformTests` compiles the existing platform test sources in a
minimal Catalyst app host. The hostless SwiftPM Catalyst runner does not create
an application lifetime suitable for mounting `UIWindow`; explicit controller
appearance calls without a window do not exercise the required lifecycle.

```sh
xcodebuild test -project NativeSceneSmoke/NativeSceneSmoke.xcodeproj \
  -scheme RouterCatalystPlatformTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -parallel-testing-enabled NO -resultBundlePath <new-result-bundle-path> \
  CODE_SIGNING_ALLOWED=NO
```

The reusable platform CI selects this hosted target only for Catalyst and
retains the same minimum test count and zero-failure/skip requirements. The
test target's package name enables existing package-scoped test hooks without
adding public API. This host is a development fixture, not a published product.
