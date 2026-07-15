# Choosing an `EnvironmentMissingPolicy`

`@EnvironmentRouter` resolves typed navigation, modal, flow, and tab authority
through the SwiftUI environment. Focused methods cover common actions;
`router.send(_:)` and `router.send(flow:)` cover explicit intent values. When
the matching host is missing, `EnvironmentMissingPolicy` decides whether to
crash, log, or both.

## The three policies

| Policy | Debug | Release | When to use |
|---|---|---|---|
| `.crash` | `preconditionFailure` | `preconditionFailure` | App code where missing wiring is always a bug. Default. |
| `.logAndDegrade` | `Logger.error` + skipped action | `Logger.error` + skipped action | SwiftUI Previews, host-less snapshot tests, and similar out-of-app rendering paths. |
| `.assertAndLog` | `Logger.error` + `assertionFailure` | `Logger.error` + skipped action | Pre-launch production builds where you want loud signal during development without paging users on a stray missing host. |

## Selecting one

Pick the narrowest policy that still surfaces wiring bugs at the
right time:

- **Default app code** stays on `.crash`. The first router action attempted
  without its matching host fails loudly — exactly the behaviour you want once
  a real user is running the build.
- **`#Preview` blocks** use `.logAndDegrade`. Previews routinely
  render leaf views without their hosts; the unavailable action is skipped so
  the canvas stays alive, while the logged error still surfaces in the Xcode
  console.
- **TestFlight / pre-launch builds** can adopt `.assertAndLog`
  from a single ship config. Engineers see `assertionFailure`
  traps locally, but a testflight tester does not get a crash
  dialog if a stray screen forgets its host.

## How to apply it

Use the `innoRouterEnvironmentMissingPolicy(_:)` view modifier at
the boundary where the policy applies — usually one level above
the offending view tree.

```swift skip doc-fragment
#Preview {
    SettingsView()
        .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
}
```

```swift skip doc-fragment
@main
struct AppEntry: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                #if PRELAUNCH
                .innoRouterEnvironmentMissingPolicy(.assertAndLog)
                #endif
        }
    }
}
```

The setting flows through the environment, so a single modifier covers every
nested `@EnvironmentRouter` it contains, including navigation, modal, flow,
and tab actions.

## Why `.assertAndLog` is not the new default

Switching the default to `.assertAndLog` would silently soften
production behaviour for every existing adopter. `.crash` stays
the default to preserve the loud-by-default contract; opt in to
the gentler policies at the boundary where they actually fit.
