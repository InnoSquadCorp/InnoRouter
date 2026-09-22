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
dismissal completion before starting the next independent scenario; view
disappearance alone is not that completion signal. Passing `--rapid-reopen`
directly to the visionOS app additionally exercises back-to-back scenarios.

The script retains build/runtime logs and requires the final PASS marker; the
exit status of `simctl launch` alone does not prove a successful probe. It does
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
settings. Its assertions wait for state changes and retain screenshots and
accessibility hierarchies in the result bundle. Only its own launched probe is
terminated during test cleanup.

`testInspectorMountedLocaleBidirectionalStatePreservation` launches the same fixture with
`--localization-probe`, exposing app-local English/Korean/German/Arabic switches.
It changes locale and layout direction without remounting the Inspector,
checks translated execution/cancellation and recording controls, and retains
screenshots and hierarchies for right-to-left and narrow-sidebar review.
It also returns from Arabic to English and back, preserving the entered URL,
execution status, selected event, and in-progress recording.
Direction changes during a held execution must retain the pending task, without
an extra policy submission or an implicit cancellation.
These switches exist only in the probe and do not alter simulator settings.
`testInspectorPolicyPreparationAcknowledgesRequestedState` checks the fixture's
explicit Hold/Resume commands and visible state acknowledgement, including
repeating Hold without toggling it off. It then proves that the real Inspector
execution is held, cancelled without a commit, and applied after Resume.
These setup controls replace the nested native switch that once ignored a tap
on CI. No test retries, longer timeouts, or Inspector assertions were removed.

The CI gate requires all three current Inspector UI test names to pass without skips;
a passing count from an older test bundle does not satisfy the gate.

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
