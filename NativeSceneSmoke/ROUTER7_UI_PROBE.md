# Router 7 native host UI probe

`RouterInspectorProbe --router7-host-probe` selects an isolated macro-first
fixture; normal Inspector and localization launch modes remain available.
The fixture owns one `RouterStore<HostProbeRoute>` and uses real `RouterTabHost`
and `RouterSplitHost` surfaces. Typed modal requests use `@PresentationResult`.
Changing host topology uses `replaceHost(with:descriptor:)` at the owner.

Run the UI suite with an installed Xcode 27 iPad Simulator, preferably landscape:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project NativeSceneSmoke/NativeSceneSmoke.xcodeproj \
  -scheme RouterInspectorProbe \
  -destination 'platform=iOS Simulator,id=YOUR_IPAD_UUID' \
  -derivedDataPath /tmp/InnoRouter7-UI \
  -resultBundlePath /tmp/InnoRouter7-UI.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:RouterInspectorUITests/Router7HostUITests \
  CODE_SIGNING_ALLOWED=NO test
```

The eight tests cover:

- nested native sheets, typed inner/outer completion, explicit close and re-entry;
- independent native root alert and root dialog controls, plus alert acceptance/
  cancellation and confirmation dialog in a recursive child;
- replay of a retained previous modal dismiss callback after close/re-entry;
- waiter cancellation, native dismissal, and a fresh subsequent typed request;
- native tab selection with retained paths, atomic tab/split replacement, stale
  scope rejection without a state/revision change, and independent split stacks;
- complete snapshot save to the sample app's Documents directory, process
  termination/relaunch, and restored selection and both tab paths.

Screenshots and accessibility hierarchy attachments are retained before and
after each tap. Assertions check the resulting native screen and observable
Store outcome, including unchanged state/revision for stale requests. Snapshot
I/O runs off the main actor. Each test starts with fresh in-memory Store state;
only the restoration test reads the fixture file it just wrote.

This is sample-app evidence. It does not establish a production-app pilot,
physical-device behavior, OS versions not executed, or a performance scorecard.

## Xcode 27 checkpoint (2026-10-05)

On Xcode 27.0 (27A266a), Swift 6.4, iPad Pro 11-inch (M4), iPadOS 27.0
(24A434), the original runtime candidate `464921e759658a44c0e63c509b5e24d6cf527cb6`
passed all five existing Inspector UI tests and the five non-transient host
scenarios above. Root alert, root dialog, and an alert in a nested presentation
were separately reproduced as failing native display checks: the request is
admitted and the Store revision advances, but no native alert/dialog appears.
These tests intentionally preserve the missing adapter behavior as failing
coverage until a platform adapter with a verified callback settlement boundary
is implemented. They are not expected-failure annotations or skipped gates.

The first draft test selected covered parent elements with duplicate identifiers.
The final fixture uses distinct inner/outer transient identifiers and queries
hittable elements. Both the corrected nested case and independent root controls
still reproduce the native display gap. The simple typed sheet, cancellation,
stale callback, topology, and restoration assertions passed.

Original screenshot/hierarchy attachments and failed xcresults are retained by
the execution environment. Some `XCUIApplication.screenshot()` captures carried
orientation 8 despite landscape pixels; direct `simctl io screenshot` captures
are available as a visual control. New captures use `XCUIScreen.main.screenshot()`.
The report must keep native display failures separate from that capture artifact.
