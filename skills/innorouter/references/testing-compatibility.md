# Testing and version boundaries

Add the optional `InnoRouterTesting` product to test targets. `RouterTestStore`
runs production transitions and captures lifecycle events synchronously. An empty
harness is nonthrowing; supplied initial state/configuration uses `try`.

```swift
let test = RouterTestStore<AppRoute>()
_ = await test.send(.push(.product(id: "42")))
test.receiveStarted()
test.receiveCommitted { state, revision in
    state == .rootStack(path: [.product(id: "42")]) && revision == 1
}
await test.finish()
```

Assert all lifecycle events in order, including policy preparation or rejection
when relevant, complete state and revision, and finish with no unresolved requests,
deferrals/timers/waiters. `finish()` reports pending work; it is not permission to
ignore it. For suspended work use `start`, lifecycle barriers and `RouterTestRuntime`
manual clock. Wait for timer registration before advancing time. Do not broadly
skip events or use wall-clock sleeps to make assertions pass.

Run the self-contained example with an external scratch directory:

```bash
python3 scripts/validate_consumer.py --scratch-path /tmp/innorouter-skill-validation
```

The script copies the fixture and verifies its exact remote pins, active graph,
workspace state, checkout SHAs/cleanliness and SwiftSyntax prebuilt, then uses
`swift test --jobs 2 --no-parallel` with strict concurrency and warnings as errors.
Keep separate scratch paths for concurrent builds. The source repository requires
`--no-parallel`: synchronous restoration storage doubles can starve concurrent suites.

The fixture pins published **7.0.0** at **33b0da7639105cfa8e6f5acffa3badb91b5e0254**.
It requires Swift tools 6.3+, Apple platform floors iOS/tvOS 18, macOS 15,
watchOS 11 and visionOS 2. The package admits SwiftSyntax 603..<605; the fixture
uses 604.0.0. Compatible declared ranges do not prove a combined app graph.

Support is **stable 7.0.x only** (`>=7.0.0 <7.1.0`), excluding prereleases.
The 7.0.0 tag and GitHub Release were verified independently, and the exact-tag
consumer was tested. This does not qualify every patch. For another 7.0.x patch,
verify its actual tag/commit, inspect release notes and manifest/API differences,
and test the consumer while retaining its selected patch. 7.1+ requires a
separate review. The validator checks the baseline tag identity before and after
testing so a moved tag cannot silently replace the reviewed release.

Use the [support record](support.json) and the consumer's actual lock together.
Migration execution, optional feature/split composition, native UI/scene behavior,
Inspector, alternate toolchains and release preflight need their own evidence.
Release [testing API](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/Sources/InnoRouterTesting/RouterTestStore.swift)
and [release guide](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/RELEASING.md)
remain the detailed references.
