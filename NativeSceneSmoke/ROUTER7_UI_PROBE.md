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

The fifteen tests cover:

- nested native sheets, typed inner/outer completion, explicit close and re-entry;
- independent native root alert and root dialog controls, plus alert acceptance/
  cancellation and confirmation dialog in a recursive child;
- policy-rejected selections that redisplay, deferred selections resolved with
  allow/reject/cancel, and iPad action-sheet outside cancellation with and without
  a declared cancel action;
- replay of a retained previous modal dismiss callback after close/re-entry;
- duplicate and stale transient callbacks using a captured public handle, plus
  canonical removal while the native alert is visible and subsequent re-entry;
- waiter cancellation, native dismissal, and a fresh subsequent typed request;
- native tab selection with retained paths, atomic tab/split replacement, stale
  scope rejection without a state/revision change, and independent split stacks;
- complete snapshot save to the sample app's Documents directory, process
  termination/relaunch, and restored selection and both tab paths.

Screenshots and accessibility hierarchy attachments are retained before and
after each tap. Assertions check the resulting native screen and observable
Store outcome, including unchanged state/revision for stale requests. Snapshot
I/O runs off the main actor. Each test starts with fresh in-memory Store state;
only the restoration test reads the fixture file it just wrote. Test-only Darwin
notifications resolve a deferred policy or invoke a captured handle while a native
alert blocks the owner controls. They do not manufacture a selected value or
change the navigation state outside the Store APIs.

This is sample-app evidence. It does not establish a production-app pilot,
physical-device behavior, OS versions not executed, or a performance scorecard.

## Xcode 27 checkpoint (2026-10-05)

On Xcode 27.0 (27A266a), Swift 6.4, iPad Pro 11-inch (M4), iPadOS 27.0
(24A434), the original runtime candidate `464921e759658a44c0e63c509b5e24d6cf527cb6`
passed all five existing Inspector UI tests and the five non-transient host
scenarios above. Root alert, root dialog, and an alert in a nested presentation
were separately reproduced as failing native display checks: the request is
admitted and the Store revision advances, but no native alert/dialog appears.
This checkpoint preserved the missing adapter behavior as failing coverage.
The tests were not marked as expected failures and were not skipped. Subsequent
adapter implementation and verification are recorded below.

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

## Native adapter follow-up (2026-10-05)

With the UIKit transient adapter installed, root alert, root dialog, and recursive
child alert/dialog passed. The expanded run passed 13 of 14 cases, including
selection rejection and all deferred allow/reject/cancel resolutions. Its one
remaining failure showed that outside cancellation of a dialog with a declared
cancel action incorrectly returned the declared value. The retained video shows
`Dialog value false`, so the assertion was kept at `Dialog dismissed`.

After the adapter distinguished popover outside dismissal and serialized native
presentation completion, the follow-up run passed all eight selected tests:
the two outside-dismissal cases, the captured transient callback/removal case,
and all five existing Inspector UI tests. Screenshots confirm the outside-
dismissed popover and the externally removed alert are absent from the screen.
The callback case confirms duplicate/stale selections are rejected with unchanged
state/revision, canonical removal returns `dismissed`, and another native alert
can be accepted. Explicit alert cancel still returns its declared typed `false`.
The app's native animations remain enabled.

The executions together cover all fifteen host cases and the five original
Inspector cases; they are separate runs, not a single 20-test result bundle.
Retained result bundles/logs are `router7-transient-adapter2` (13/14) and
`router7-native-final8` (8/8), with exported summaries and attachments. Earlier
red display and invalid UIKit delegate experiments are preserved separately.
These results describe the sample fixture on the listed iPadOS 27 Simulator.
They do not extend the original checkpoint SHA's claims to a newer runtime or
establish other OS versions, physical devices, or a production-app pilot.
