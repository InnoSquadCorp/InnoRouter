# Restoration process probe

This development fixture verifies real scene background persistence and process
restart through the public macro, host, and restoration modifier. XcodeGen is
only needed to generate this fixture's local project; it is not a package dependency.

Generate with `xcodegen generate --spec NativeSceneSmoke/Restoration/project.yml`.
Build the generated project for a dedicated iOS simulator, then install
`com.innosquad.InnoRouterRestorationProbe` and launch it with `--seed`.

The app's Application Support/RestorationProbe/ready.txt marker proves its detail
navigation was applied. Its one-hour debounce deliberately requires the lifecycle
flush: move the app into the background (for example, open Settings), and wait for
saved.txt. Only then terminate the probe. Launch it again without arguments and
require result.txt to contain `PASS restored detail after process restart`.

The seed argument removes only this probe's snapshot and markers. Read result.txt
for failures; launch success alone is not proof. Record the exact runtime and
source revision. An iOS 18.6 run verifies that runtime, not every iOS 18 release.
