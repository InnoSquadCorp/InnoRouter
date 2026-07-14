# Choosing an `EnvironmentMissingPolicy`

InnoRouter property wrappers (`@EnvironmentRouter`,
`@EnvironmentNavigationIntent`, `@EnvironmentModalIntent`, and
`@EnvironmentFlowIntent`) resolve their dispatcher through the SwiftUI
environment. `@EnvironmentRouter` is the macro-first stack API; the intent
wrappers remain available for lower-level modal, flow, and custom-intent code.
When the matching host is missing, `EnvironmentMissingPolicy` decides whether
to crash, log, or both.

## The three policies

| Policy | Debug | Release | When to use |
|---|---|---|---|
| `.crash` | `preconditionFailure` | `preconditionFailure` | App code where missing wiring is always a bug. Default. |
| `.logAndDegrade` | `Logger.error` + no-op dispatcher | `Logger.error` + no-op dispatcher | SwiftUI Previews, host-less snapshot tests, and similar out-of-app rendering paths. |
| `.assertAndLog` | `Logger.error` + `assertionFailure` | `Logger.error` + no-op dispatcher | Pre-launch production builds where you want loud signal during development without paging users on a stray missing host. |

## Selecting one

Pick the narrowest policy that still surfaces wiring bugs at the
right time:

- **Default app code** stays on `.crash`. Production cold-starts
  will fail loudly and immediately on a missing host — exactly
  the behaviour you want once a real user is running the build.
- **`#Preview` blocks** use `.logAndDegrade`. Previews routinely
  render leaf views without their hosts; the no-op dispatcher
  keeps the canvas alive and the logged error still surfaces in
  the Xcode console.
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

The setting flows through the environment, so a single modifier
covers every nested `@EnvironmentRouter`,
`@EnvironmentNavigationIntent`, `@EnvironmentModalIntent`, and
`@EnvironmentFlowIntent` it contains.

## Why `.assertAndLog` is not the new default

Switching the default to `.assertAndLog` would silently soften
production behaviour for every existing adopter. `.crash` stays
the default to preserve the loud-by-default contract; opt in to
the gentler policies at the boundary where they actually fit.
