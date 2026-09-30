# InnoRouterTesting

A host-less assertion harness for the canonical InnoRouter 6 transition
pipeline.

## Overview

`RouterTestStore<Route>` wraps the production `RouterStore`, reducer, and
policies. It buffers events synchronously, allowing a test to assert the exact
`started → policyPrepared → committed/rejected` lifecycle without sleeps.

```swift skip doc-fragment
import InnoRouter
import InnoRouterTesting
import Testing

@Test @MainActor
func opensDetail() async {
    let store = RouterTestStore<AppRoute>()

    await store.send(.push(.detail(id: "42")))
    store.receiveStarted()
    store.receiveCommitted { state, revision in
        state == .rootStack(path: [.detail(id: "42")]) && revision == 1
    }
    store.finish()
}
```

The default `TestExhaustivity.strict` mode records a Swift Testing issue when
events remain at `finish()` or deinitialization. Use `.off` only while
incrementally migrating a large suite. Production `onEvent` callbacks are
preserved and run before an event enters the assertion queue.

Use predicates when a transition identifier is generated at runtime, or compare
an exact `RouterEvent` when the fixture owns every value.

`send(_:context:)` accepts production transition provenance and animation;
passing a `RouterPlan` applies one exact target. Codable routes can use
`snapshot(using:)` and `restore(from:using:recovery:)` to verify the same codec,
migration, policy, and provenance path used by an application. `assertState`
and `receiveUnchanged` complete the value-level assertion surface.

For timeout, expiry, cancellation, and overlapping-request tests, install a
`RouterTestRuntime` and start requests without awaiting them:

```swift skip doc-fragment
let runtime = RouterTestRuntime(transitionIDSeed: 1)
let store = RouterTestStore<AppRoute>(
    configuration: .init(policyTimeout: .seconds(30)),
    runtime: runtime
)
let request = store.start(.push(.checkout))

await request.waitUntilStarted()
await runtime.clock.waitUntilScheduled()
runtime.clock.advance(by: .seconds(30))
let outcome = await request.result
```

The start and timer-registration barriers are production lifecycle signals,
not scheduler guesses. `RouterTestRequest.cancel()` targets one request, while
`waitForEvent(where:)` waits for an exact later lifecycle condition. Strict
`finish()` reports outstanding requests, policy deferrals, and virtual timers,
then cancels only work created by this test harness. Existing test-store
initializers retain live time unless a runtime is explicitly supplied.

`RouterActionSequence<Route>` stores Codable production actions and each step's
`RouterTransitionContext` as a versioned, deterministically encoded fixture.
Construct `RouterActionStep` values when provenance, animation, request keys,
coalescing, or resumed-deferral metadata differ between steps. The convenience
`init(actions:context:)` applies one context to every action. `replay(on:)` sends
each step through `RouterTestStore`, including production policy rejection.

Supply the original initial state, policies, and runtime dependencies when
constructing the test store. Replay is sequential and does not reproduce
concurrent request timing. Fixtures contain route payloads and request keys;
review them before sharing. Use Inspector bundles for redacted support exports.

`RouterScenarioRecorder` is the explicit bridge from a reproduced bug to a
regression fixture. It observes request, start, cancellation, and terminal
boundaries synchronously, bounds retained route payloads, and reports
unfinished, dropped, or control-incomplete requests. Format v5 records
route-schema, environment, dependency/effect capabilities, the initial
revision, every request's relative `expectedRevision`, its
``RouterScenarioCancellationOrigin``, serializable
``RouterScenarioRequestSemantics``, and logical submit, wait, cancel,
virtual-time, deferral-resolution, and terminal controls. This preserves
history navigation-only rebasing and stale-state checks through queued and
repeatedly deferred requests. Format v7 records the complete feature mapping
path for ordinary feature actions, presentation mutations, completions, and
feature plans. Scene-local requests bind ownership to the logical Scene
lifetime created by the replay sequence rather than serializing process-local
UUID tokens. Replay requires a
``RouterScenarioFeatureResolver`` built from the same macro-generated mapping;
use ``RouterScenarioFeatureProjection`` to compose nested mappings. Missing,
duplicate, or tampered resolver paths fail before the first production request.
Format v6 and earlier, plus unknown future versions, are rejected
instead of guessing execution conditions. Use the recorder's `resolveDeferred` and
`advanceTime` operations when
capturing those decisions so replay never invents unavailable scheduling data.
Preflight validates the exact action provenance stored by each deferral while
allowing a history target to differ from the merged state that preserves
already-open scenes, badges, and non-conflicting presentations. A resumed
history request with an explicit request-cancellation control is portable. A
request cancelled by an unrecorded history stop or reset is rejected as
``RouterScenarioReplayError/unsupportedHistoryLifetime(step:)`` (and by the
matching source-generation error) before replay mutates a store; reproduce and
record that lifecycle explicitly before generating a portable fixture.
A raw recording is intentionally incomplete:
`RouterScenarioFixture.settingExpectations(_:)` must provide a developer-owned
`RouterScenarioExpectation` for every observation before
`RouterScenarioSourceGenerator` emits Swift Testing source. Generated tests use
``RouterScenarioRunner`` to preserve overlaps, cancellation, timeout, and
approval controls, map fresh deferral identities, and compare each request's
own terminal snapshot and revision delta on the production test store. Replay
preflights a caller-declared ``RouterScenarioReplayEnvironment`` before the
first request and requires the test store's complete state to equal the
fixture's initial state. If replay fails or its task is cancelled, it cancels
and drains its own request and deferral handles before returning while leaving
unrelated store work untouched.
``RouterScenarioSourceGenerator/generateFiles(_:routeTypeName:fixtureFileName:testName:storeFactory:environmentFactory:featureResolversFactory:)``
returns separate Swift Testing and JSON fixture artifacts. Use
`RouterScenarioFixture.decode(from:maximumByteCount:maximumStepCount:)` at an
import boundary.

## Topics

### Harness

- ``RouterTestStore``
- ``TestExhaustivity``
- ``RouterActionSequence``
- ``RouterActionStep``
- ``RouterTestRuntime``
- ``RouterTestClock``
- ``RouterTestRequest``
- ``RouterTestPendingWork``
- ``RouterScenarioRecorder``
- ``RouterScenarioFixture``
- ``RouterScenarioControl``
- ``RouterScenarioRequestSemantics``
- ``RouterScenarioSceneLifetime``
- ``RouterScenarioCancellationOrigin``
- ``RouterScenarioExpectation``
- ``RouterScenarioMetadata``
- ``RouterScenarioReplayEnvironment``
- ``RouterScenarioFeatureProjection``
- ``RouterScenarioFeatureResolver``
- ``RouterScenarioGeneratedFiles``
- ``RouterScenarioSourceGenerator``
- ``RouterScenarioRunner``
