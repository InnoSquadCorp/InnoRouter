# Changelog

All notable changes to InnoRouter are documented here. This project
follows [Semantic Versioning](https://semver.org/) — release tags
are bare semver (no leading `v`).

## Unreleased

### Breaking

- The minimum supported Swift version is now 6.3
  (`swift-tools-version: 6.3`), aligned with `swift-syntax` 603.x and the
  Xcode 26.6 / Swift 6.3 release gates. Consumers building with Swift 6.2 must
  upgrade their toolchain before adopting InnoRouter 5.0.
- The default `InnoRouter` umbrella now includes and re-exports
  `InnoRouterMacros`. A standard app target therefore resolves the compiler
  plugin and uses `import InnoRouter` for both runtime APIs and macros. Targets
  that deliberately need a macro-free dependency surface should depend on a
  granular product such as `InnoRouterCore`, `InnoRouterSwiftUI`, or
  `InnoRouterDeepLink` instead.
- visionOS scene routing and ornaments now ship in the opt-in
  `InnoRouterSpatial` product. Add that product dependency and
  `import InnoRouterSpatial` at spatial call sites. `ScenePresentation`,
  `ImmersiveStyle`, `VolumetricSize`, and `OrnamentAnchor` moved out of
  `InnoRouterCore`; `SceneStore`, its contracts, and the scene/ornament view
  modifiers moved out of `InnoRouterSwiftUI`. The `InnoRouter` umbrella does
  not re-export Spatial, keeping non-spatial apps free of that surface.
- `SceneDeclaration` is now factory-only and `SceneRegistry` is opaque after
  construction. Build declarations with `.window`, `.volumetric`, or
  `.immersive`, then pass the registry to `innoRouterSceneHost` and
  `innoRouterSceneAnchor`. Raw declaration fields, `Kind`, the raw initializer,
  registry storage, and lookup methods are no longer public. Reuse stable scene
  identifier constants in the registry and matching SwiftUI scene declarations.
- The visionOS spatial surface now exposes only app-facing authority.
  `SceneHost` and `SceneAnchor` are implementation details behind
  `View.innoRouterSceneHost` and `View.innoRouterSceneAnchor`;
  `SceneStore.pendingIntent`, `completeOpen`, `completeDismissal`, and
  `completeRejection` were host-dispatch plumbing and have been removed.
  The unattached `innoRouterSceneHost(_:scenes:)` overload is also removed;
  every host now identifies its containing route, and window/volume hosts pass
  the value-based `WindowGroup` instance ID so lifecycle inventory stays exact.
  Apps should issue requests through `SceneStore`, observe `events`, and attach
  the public view modifiers instead of driving dispatch completion directly.
- Middleware handles are now issued only by store registration operations.
  `NavigationMiddlewareHandle()` and `ModalMiddlewareHandle()` are no longer
  public, and the redundant `middlewareHandles` snapshots are removed from
  both stores. Keep the handle returned by `addMiddleware` / `insertMiddleware`,
  or read handles and debug labels together through `middlewareMetadata`.
- `NavigationStoreConfiguration.engine` and its initializer argument are
  removed. `NavigationEngine` is stateless and had no interchangeable
  implementation, so every `NavigationStore` now creates the same engine
  internally. Direct `NavigationEngine` use remains public for command-model
  validation and standalone state transitions. For the same reason,
  `NavigationCommand.validate(on:using:)` and `canExecute(on:using:)` remove
  their redundant `using:` argument; call `validate(on:)` or `canExecute(on:)`,
  or invoke `NavigationEngine.apply(_:to:)` directly when applying a sequence
  against one mutable preview stack.
- The `logger` stored by each `OSLog*TelemetrySink` is now private. Configure
  these adapters through `init(logger:)`; retain the original `Logger`
  separately if the app also needs to use it directly.
- `DebouncingNavigator.inner` is now private. Keep the wrapped navigator at
  the composition site when immediate execution or state inspection is also
  required, instead of reaching through the debounce wrapper.
- `.whenCancelled(primary, fallback:)` now evaluates each attempted leg behind
  a separate savepoint. If the fallback also fails or is cancelled, its partial
  state is discarded, the original snapshot remains authoritative, and no
  `.changed` event is emitted. Transaction results now retain effective engine
  attempts from both primary and fallback, including discarded attempts when
  the fallback commits. Transaction leg selection still uses preview results so
  `didExecute` remains commit-only; a post-commit result fold changes reporting
  but cannot undo the commit or reopen fallback selection.
- `executeTransaction([])` now returns `isCommitted == false`, matching the
  existing empty `.sequence([])` and empty batch failure semantics. Its
  `failureIndex` remains `nil` because no command ran. Concrete commands with
  empty payloads keep their established meanings: `.pushAll([])` is a
  successful no-op and `.replace([])` successfully clears the stack.
- The duplicate Umbrella `DeepLinkCoordinating` protocol and
  `DeepLinkCoordinationOutcome` enum are removed. Coordinator-based apps now
  add the opt-in `InnoRouterEffects` product and own one
  `DeepLinkEffectHandler`, created with `init(pipeline:navigator:)`.
  Migrate `handleDeepLink(_:)` to `handle(_:)`,
  `resumePendingDeepLinkIfPossible()` to `resumePendingDeepLink()`, and the
  old outcome type to `DeepLinkEffectHandler.Result`. Pending state is
  read-only through the handler; use `restore(pending:)` or
  `clearPendingDeepLink()` for explicit writes. The handler snapshots its
  pipeline at initialization, so keep live authentication or policy state in
  the pipeline's closures and mirror returned results into coordinator state
  when Observation integration is required.
- `FlowPlanApplyResult.rejected` and
  `FlowDeepLinkEffectHandler.Result.applicationRejected` now carry the exact
  `FlowRejectionReason`. Custom `FlowPlanApplier` conformers must return a
  reason for every rejection, and exhaustive result patterns must accept the
  new payload. Reentrant `FlowStore.apply(_:)` calls now report the new
  `.reentrantApply` reason instead of an unclassified rejection.
- Push-only deep-link outcomes add
  `.executionFailed(plan:batch:)`. `DeepLinkEffectHandler` now reserves
  `.executed` for batches whose commands all succeed; middleware cancellation
  or a runtime command failure returns the new case with any partial state and
  per-command results. Update exhaustive switches to handle
  `.executionFailed`. Preflight failures remain `.applicationRejected` and do
  not execute the batch.
- `NavigationEffectHandler` now exposes only result-bearing command, batch,
  transaction, and guarded execution methods. The result-discarding `push`,
  `pop`, `popToRoot`, and `replace(with:)` wrappers are removed; call
  `execute(_:)` with the corresponding `NavigationCommand` and inspect its
  result. The two batch overloads are folded into
  `execute(_:stopOnFailure:)`, whose default remains `false`, so existing
  batch call syntax is unchanged. The unused `canExecuteSequentially(_:)`
  helper and public `state` mirror are also removed. Retain the injected
  navigator when its state must be read independently, and use
  `NavigationPlan.validationFailure(on:)` when preflighting a deep-link plan.
- Both deep-link effect handlers replace duplicate throwing and nonthrowing
  `resumePendingDeepLinkIfAllowed(_:)` overloads with one `async rethrows`
  method. Existing throwing and nonthrowing call sites keep the same syntax.
- The source-compatibility `InnoRouterNavigationEffects` and
  `InnoRouterDeepLinkEffects` products and modules are removed as planned for
  the 5.0 boundary. Their handlers, effect protocols, and DocC articles now
  live directly in the single `InnoRouterEffects` product. Replace either
  legacy import and any explicit package product dependency with
  `InnoRouterEffects`; the public type names and runtime behavior are
  otherwise unchanged.
- Store observation configuration is consolidated into one callback per
  authority. `NavigationStoreConfiguration` removes `onChange`,
  `onBatchExecuted`, `onTransactionExecuted`, `onMiddlewareMutation`, and
  `onPathMismatch`; `ModalStoreConfiguration` removes `onPresented`,
  `onDismissed`, `onReplaced`, `onQueueChanged`, `onCommandIntercepted`, and
  `onMiddlewareMutation`; and `FlowStoreConfiguration` removes
  `onPathChanged` and `onIntentRejected`. Migrate each group to its
  configuration's `onEvent` callback and switch over `NavigationEvent`,
  `ModalEvent`, or `FlowEvent`. The existing `events` `AsyncStream` remains
  the asynchronous observation surface. `FlowStoreConfiguration.onEvent`
  also receives inner-store activity as `.navigation(...)` and `.modal(...)`,
  so one callback can observe the complete flow without separately wiring
  the nested configurations. This is a 5.0 source-breaking change; no
  compatibility callback shims are provided.
- `FlowCoordinator` and `FlowCoordinatorView` are now
  `StepCoordinator` and `StepCoordinatorView`, clarifying that this
  helper owns checklist progress rather than navigation/modal state.
  The separate `FlowStep.index` contract is removed; step order now
  follows `Step.allCases`, including a manually supplied non-empty,
  unique order. The unused `Result`, `onComplete`, and
  `complete(with:)` protocol requirements are also removed so
  completion remains app-owned.
- `DeepLinkParser`, `DeepLinkPattern`, and their nested result types
  are now implementation details behind `DeepLinkMatcher` and
  `DeepLinkMapping`. The unused `DeepLinkable` protocol is removed.
- `DeepLinkMatcher`, `DeepLinkMapping`, and `DeepLinkMappingBuilder` now
  describe their `Sendable` output directly. Single-route matchers continue
  to use `DeepLinkMatcher<AppRoute>`; composite matchers now use
  `DeepLinkMatcher<FlowPlan<AppRoute>>`. The duplicate
  `FlowDeepLinkMatcher`, `FlowDeepLinkMapping`, and
  `FlowDeepLinkMappingBuilder` types, including their array-only
  initializers, are removed. Dynamic mappings remain supported through
  array expressions or `for` statements in the shared result builder; no
  compatibility aliases are provided.
- Deep-link pipelines and effect handlers now expose outcomes instead of
  their injected implementation state. The configuration stored by
  `DeepLinkPipeline` and `FlowDeepLinkPipeline`,
  `DeepLinkEffectHandler.navigationHandler`, and
  `FlowDeepLinkEffectHandler.pipeline` are no longer public. Pass all
  configuration through the existing initializers; retain any matcher,
  pipeline, navigator, or store separately when it must be reused; and inspect
  `decide`, `handle`, or `resumePendingDeepLink` results for execution
  outcomes.
- Output-only deep-link values no longer expose public construction or
  duplicate convenience state. `DeepLinkParameters` and
  `NavigationPlanValidationFailure` are created by the matcher and plan
  validator, respectively; `DeepLinkParameters.firstValuesByName` is removed
  in favor of `firstValue(forName:)` for named access or
  `valuesByName.compactMapValues { $0.first }` for the full projection; and
  both effect handlers remove
  `hasPendingDeepLink` in favor of `pendingDeepLink != nil`. The unused
  `RouterEffect` marker is removed; effects that support both operations can
  conform directly to `NavigationEffect` and `DeepLinkEffect`.
- Output-only SwiftUI diagnostics no longer expose public memberwise
  construction. Middleware metadata and mutation events, path-mismatch events,
  and state-restoration failures remain public readable values emitted by their
  owning stores and adapters, but their initializers are now framework-only.
- Telemetry sinks now use the canonical `NavigationEvent`, `ModalEvent`, and
  `FlowEvent` names directly. The redundant `NavigationTelemetryEvent`,
  `ModalTelemetryEvent`, and `FlowTelemetryEvent` aliases are removed; update
  explicit annotations and custom sink method signatures to the canonical
  event types.
- The unused `FlowNavigating` forwarding protocol is removed. Flow owners
  should keep a `FlowStore` directly and dispatch with `send(_:)` or its cached
  `intentDispatcher`; `FlowHost` already consumes that store-native dispatcher.
- `DeepLinkPipeline` now accepts a `DeepLinkMatcher` through its canonical
  `matcher:` initializer. The old `resolve:` initializer and nested `Resolver`
  type alias are removed. Migrate `resolve: { matcher.match($0) }` to
  `matcher: matcher`; use the explicitly named `customResolver:` initializer
  only for arbitrary URL-to-route closures. No compatibility overload is
  provided.
- `InnoRouterTesting` removes the legacy `NavigationTestEvent`,
  `ModalTestEvent`, and `FlowTestEvent` aliases. Test stores now expose the
  canonical `NavigationEvent`, `ModalEvent`, and `FlowEvent` types directly;
  replace explicit alias annotations with those production event names.
- `InnoRouterTesting` replaces the terminal-sounding
  `expectNoMoreEvents()` checkpoint with `assertNoPendingEvents()`.
  The renamed method reports and consumes only the current queue
  snapshot. `finish()` is now the sole terminal operation: it drains
  the final snapshot, is idempotent, and reports the first event emitted
  after completion even when exhaustivity is `.off`. Migrate end-of-test
  calls to `finish()`; use `assertNoPendingEvents()` only for checkpoints
  between test phases.

### Added

- `@Router` is the macro-first SwiftUI entry point. Developers declare an enum
  and one `var destination: some View` switch; the macro supplies `Route` and
  `DestinationRoute` conformance, `@MainActor`, `@ViewBuilder`, and the host
  witness. Invalid attachment, missing or malformed destinations, conflicting
  manual witnesses, empty routers, and redundant conformance now produce
  stable compiler errors or warnings at the declaration site.
- `RouterHost` owns the `NavigationStore` for a simple stack, while
  `@EnvironmentRouter` exposes short typed actions such as `go`, `back`, and
  `backToRoot` to descendants. Applications that need external store access,
  restoration, middleware mutation, or deep-link orchestration can continue
  with `NavigationHost(store:)` without changing their route type.
- `@DeepLink` gives `@Router` enums a typed, fail-closed `DeepLinkRoute`
  resolver from literal scheme, host, and path declarations. Generated
  matching uses deterministic specificity precedence—literal paths, typed
  parameters, then terminal wildcards—and emits compiler diagnostics for
  invalid origins, payload mismatches, conditional mappings, and normalized
  duplicates.
- Macro-first hosts now consume those generated resolvers automatically:
  `RouterHost` and `RouterSplitHost` push one resolved route, while
  `RouterTabHost` selects one resolved tab. Nested hosts arbitrate one incoming
  URL in favor of the shallowest matching authority inside the selected scene;
  multi-window scene selection, modal style, authentication, pending replay,
  and multi-step plans remain explicit.
- `@EnvironmentSceneRouter` exposes one route-aware spatial action facade from
  both `innoRouterSceneHost` and `innoRouterSceneAnchor`. `open(_:)` selects the
  declared window, volumetric, or immersive behavior automatically and returns
  an optional request handle; `dismissWindow(_:)` preserves multi-window
  identity, while `dismissImmersive()` follows SwiftUI's active-space model.
  `SceneStore.openImmersive` now returns the same request handle as the other
  open methods.
- `@SceneRouter` and case-level `@Scene` add macro-first spatial scene
  declarations in the opt-in `InnoRouterSpatial` product. Every parameterless
  case declares `.window`, `.volumetric(...)`, or `.immersive(...)` metadata
  with an optional stable `id`, while one `var destination: some View` supplies
  generated `DestinationRoute` conformance and the complete `AppScene.scenes`
  tree. The first case becomes the primary host and later cases become lifecycle
  anchors; immersive-first launch contracts require an explicit acknowledgement.
  Invalid scene inventories and generated-member conflicts fail at compile time
  with stable diagnostics.

### Changed

- Release publication now resolves strict GA/`rc`/`beta` metadata through one
  SemVer policy, reads release policy from `main`, verifies the exact tag and
  triggering SHA against `main` ancestry, and builds only the resulting
  immutable commit. Pre-release tag pushes complete as validated publication
  no-ops; manual `prerelease=true` dispatch remains the publishing path.
- Release preflight now validates `CHANGELOG.md` from the tag commit. GA cuts
  must empty `Unreleased` and place the tagged version immediately below it;
  pre-releases keep non-empty notes under a leading `Unreleased` section until
  the GA cut; placing it below an existing release is rejected.
- Apple-platform CI now compiles all eight public library products explicitly,
  guards the Swift/Xcode pin matrix, and runs `actionlint` on every pull request
  and branch push. Pull-request concurrency uses the repository-unique PR number
  so identically named branches from different forks cannot cancel one another.
- The documentation snippet gate now depends on every public product and
  compile-checks an `InnoRouterEffects` import/use example, closing the only
  opt-in product coverage gap in the consumer fixture.
- Changelog contributions now edit `CHANGELOG.md` under `## Unreleased`
  directly. The unused `.changes` fragment convention is removed; release cut
  moves those entries under the version/date heading and reopens `Unreleased`.
- The repository's active compatibility policy now describes the 5.x release
  line and reserves new source- or behavior-breaking changes for 6.0. Release,
  contribution, security, workflow, and localized README guidance use the same
  contract while retaining the 4.x migration history as historical context.
- Deep-link matching now parses accepted-size URLs at most once per
  matcher, push-pipeline, or flow-pipeline decision, while preserving the raw
  URL length rejection at each entry point before that entry point parses.
  `DeepLinkMatcher.match`, `DeepLinkPipeline.decide`, and
  `FlowDeepLinkPipeline.decide` previously
  re-parsed the same URL up
  to four times (input-limit checks and pattern walks each parsed
  independently); they now thread a single parsed value through
  content-limit validation and pattern matching. URLs rejected by the
  entry point's raw-length gate are not parsed.
- Package-only execution tracing and middleware cleanup hooks now use
  Swift's `package` access level instead of public SPI declarations.

### Fixed

- Swift 6.3 CI jobs now run on the `macos-26` runner image and pin Xcode 26.6.
  The previous `macos-15` / Xcode 26.3 combination selected Swift 6.2.4 and
  rejected the package manifest before tests, DocC, coverage, performance, or
  platform gates could run. The visionOS discovery floor also follows Xcode
  26.6's function-level `xcresult` summary while parameterized test iterations
  remain validated by the test result itself.
- Performance smoke measurements now alternate small/large input order, report
  median timings, and gate scaling on the median of five pair ratios instead of
  dividing two independently aggregated medians. Transient runner preemption no
  longer masquerades as an input-scaling regression, while a slowdown present
  in at least three of five pairs still fails the unchanged ratio and
  absolute-time budgets. Failed runs also preserve the JSON report and print
  every regressed sample instead of exiting before diagnostics. Deterministic
  self-tests cover tolerated outliers and threshold/cap boundaries, while the
  wrapper rejects empty, incomplete, or internally inconsistent reports.
- Reopening an already-active immersive scene with the same route and style now
  reuses its presentation identity. A successful duplicate open can no longer
  replace the store's active UUID while the live SwiftUI root still owns the
  previous UUID, so lifecycle teardown reliably removes the scene.
- Cancelling a visionOS scene host while it awaits cleanup of a superseded
  immersive open now reconciles and releases the claimed request before the
  dispatch loop exits. Queued scene requests no longer remain permanently
  blocked behind an `awaitingSupersededImmersiveOpenCleanup` claim.
- Release publishing now fails closed when the existing `gh-pages` site cannot
  be checked out or lacks its root portal, and every version unconditionally
  merges that snapshot before deployment. All release runs share a queued
  concurrency group, preventing simultaneous tags from publishing stale site
  snapshots that erase one another or older versioned documentation. The two
  third-party actions receiving write tokens are pinned to immutable commits.
- Versioned DocC publication compares every GA against the highest existing GA
  before rebuilding `/latest/`, so rerunning an older tag cannot roll the alias
  back. GitHub's Latest Release flag follows the same monotonic decision instead
  of its default newest-publication behavior. Both surfaces consume one tested
  publication resolver covering lower, equal, higher, and prerelease versions.
  The root portal uses the shared SemVer ordering, placing a GA ahead of its
  `rc`/`beta` builds and ordering numeric prerelease ordinals correctly.
- Apple-platform runtime CI now treats a timed-out asynchronous `simctl boot`
  request as provisional and lets authoritative `bootstatus` decide readiness,
  avoiding false failures when the simulator continues booting successfully.
  When several runtime images are installed, it deterministically selects the
  highest available version instead of relying on JSON enumeration order.
- Versioned DocC source links now use the exact GA, release-candidate, or beta
  tag. Pre-release builds such as `5.0.0-rc.1` no longer send “View Source”
  links to a potentially newer `main`; preview builds remain pinned to their
  commit SHA.
- The public-API changelog gate now compares substantive `Unreleased` content
  against the merge base, so an edit to historical release prose or whitespace
  cannot satisfy a baseline change. Pull requests use the base SHA and branch
  pushes use the event's previous SHA, preventing main/develop checks from
  comparing `HEAD` with itself and silently skipping validation.
- Spatial scene inventory now tracks each live host or anchor root independently
  from primary-dispatcher election. Dormant value-based windows participate in
  appear/disappear reconciliation, overlapping roots detach a shared scene only
  after their final owner disappears, and immersive hosts unregister by a stable
  lifecycle token so SwiftUI view recreation cannot leave a stale presentation.
- Spatial fallback anchors now authorize opens by `SceneDeclaration` instead of
  exact presentation UUID. A value-based window can therefore open another
  instance of its own declared scene while the primary host is absent; genuinely
  cross-scene opens remain rejected with `.fallbackCannotDispatch`.
- The rejection-reasons catalog now covers every cancellation/rejection enum
  case and reflects the actual immersive-dismiss distinction between an empty
  inventory and a non-immersive active scene. The docs consistency gate now
  fails when a new reason is added without a matching catalog entry.
- Push and flow deep-link effect handlers now identify pending replay requests
  by an internal revision instead of value equality. If an equal URL and plan
  is handled again—or, for flow links, restored—while an asynchronous
  authorization probe is in flight, the older probe no longer consumes the
  newer request; it returns the replacement as `.pending` for an explicit
  replay.
- Push deep-link pipelines and `DeepLinkEffectHandler` now preserve a
  matcher's input-limit violation as
  `.rejected(.inputLimitExceeded(...))`. Wrapping `matcher.match` in the old
  optional resolver erased the distinction between a rejected input and an
  unmatched URL, causing the former to surface incorrectly as `.unhandled`.
  Push and flow pipelines now share the same atomic admission path and
  rejection precedence.
- Deep-link paths now split on their percent-encoded separators before each
  segment is decoded exactly once. An encoded slash (`%2F`) remains data
  inside one segment instead of matching a two-segment pattern, `%252F`
  resolves to the literal `%2F` instead of being decoded twice, and path
  segment limits use the same boundaries as pattern matching.
- Deep-link diagnostics no longer report duplicate or shadowing cascades from
  patterns that cannot match because of an invalid parameter name. Intrinsic
  invalid-pattern diagnostics remain unchanged, while pairwise diagnostics
  among valid mappings retain their original declaration indices.
- Reentrant `FlowStore.send(_:)` calls made by nested navigation or modal
  `onEvent` callbacks and telemetry sinks now wait for the originating
  inner-store operation and complete Flow mutation to finish. This includes
  path reconciliation and partial-commit rejection/coalescing, preserving
  wrapped-event and `pathChanged` ordering without losing the nested intent.
  Because `FlowStore.apply(_:)` returns its result synchronously, reentrant
  calls from Flow or inner-store observation callbacks and telemetry sinks are
  rejected without mutation; use `send(.reset(...))` when the follow-up reset
  should be queued.
- Test stores now copy the complete production configuration before
  composing their `onEvent` callbacks. Previously the wrappers reset
  custom telemetry sinks, event buffering, path reconciliation, modal
  queue cancellation, and flow queue coalescing to their defaults.
  All three wrappers preserve the user's callback; `ModalTestStore` and
  `FlowTestStore` also enqueue the corresponding `.replaced` event.
- OSLog telemetry now treats route, command, middleware debug-name,
  dismissal-reason, full event-summary, and arbitrary runtime error
  payloads as private hash-masked values. Event kinds, counts, policies,
  and outcomes remain public so logs stay useful without exposing
  route-associated values.
- `StepCoordinator.jump(to:)` now applies the same `canProceed(from:)`
  gate as `next()` when jumping forward, and only permits forward
  jumps to the immediate next step in progression order. Backward
  jumps and jumps to already-completed steps remain unrestricted.
  Previously a forward jump could bypass a step that `next()` would
  have blocked.

## 4.3.0 - 2026-06-24

4.3.0 keeps the 4.x public API surface compatible while hardening the
runtime and release toolchain against Swift 6.3 / Xcode 26.3 compiler
and CI drift.

### Fixed

- `EventBroadcaster` now stores subscriber continuations in a private
  helper whose nonisolated deinitializer finishes outstanding streams.
  This avoids the Swift 6.3 optimizer crash seen while compiling
  `InnoRouterCore` in optimized Stage / Release simulator builds, while
  preserving the existing event fan-out behavior and subscriber cleanup
  contract.

### Changed

- Release and documentation gates now resolve the macOS SDK explicitly
  when extracting symbol graphs, so `InnoRouterTesting` can reliably find
  Swift Testing's `Testing.framework` in Xcode-based environments even
  when Command Line Tools SDK discovery drifts.
- CI workflows now use the current pinned action majors
  (`actions/checkout@v7`, `codecov/codecov-action@v7`) without changing
  the package's supported Swift or platform floors.

## 4.2.1 - 2026-05-12

### Fixed

- `Package.swift` no longer uses `SwiftSetting.treatAllWarnings(as:)`.
  SwiftPM accepts that setting, but current Tuist external package conversion
  fails while decoding the Swift 6.3 manifest JSON when InnoRouter is linked as
  an external dependency. The package keeps `.swiftLanguageMode(.v6)`, and
  warnings-as-errors remain a repository gate through CI and release scripts
  instead of being imposed through the consumer-facing manifest.

## 4.2.0 - 2026-05-07

4.2.0 is the privacy manifest release. It keeps the 4.x public API
surface unchanged while making the package's privacy posture explicit
for Apple platform adopters and App Store privacy checks.

### Added

- `PrivacyInfo.xcprivacy` manifests ship with every public library
  target (`InnoRouterCore`, `InnoRouterDeepLink`,
  `InnoRouterSwiftUI`, `InnoRouter`, the effect products,
  `InnoRouterMacros`, and `InnoRouterTesting`). The manifests declare
  no tracking, no collected data types, and no required-reason API
  access because the package does not collect user data or call
  required-reason APIs directly.

## 4.1.0 - 2026-05-06

4.1.0 is the consolidated pre-adoption cleanup release. It folds
the original 4.1.0 baseline (DeepLinkInputLimits, structured
telemetry sinks, dispatcher-object cleanup, etc.) together with
the routing-surface refresh: documentation foundation,
concurrency / macro test scaffolding, the additive API surface
that fills the most acute 4.0.x gaps, and the breaking changes
that wire up the new injection / capability seams. All of it
ships together because 4.0.x was the only public OSS snapshot
and there are no production adopters yet — folding the work
into one tag avoids cutting two consecutive churn-heavy
releases.

This is a one-time pre-adoption exception that folds breaking
changes into a minor bump; additive-only SemVer guarantees resume
for later 4.x releases after this tag.

The migration is documented inline in this entry. Adopters who
ran the pre-OSS `4.0.0` snapshot follow the diffs under
"Removed" and "Changed" below; 4.0.x → 4.1.0 is a single hop.

### Added

- `Docs/CI-gates.md` — single-page reference for every gate run
  by `scripts/principle-gates.sh`, with purpose, failure signal,
  and local repro command per gate.
- `Docs/StoreSelectionGuide.md` — decision tree plus four worked
  examples (single push stack, push + independent modal, atomic
  URL → push + modal, iPad split) for new adopters choosing
  between `NavigationStore`, `ModalStore`, `FlowStore`, and the
  experimental `SceneStore`.
- `Examples/README.md` and `ExamplesSmoke/README.md` documenting
  Examples ↔ ExamplesSmoke parity rules and the macro-free
  constraint on smoke fixtures.
- `Tests/InnoRouterPlatformTests/SceneStoreVisionOSTests.swift` —
  visionOS-only platform suite pinning the spatial scene public
  envelope (handle accounting, ScenePresentation case shape,
  open/dismiss lifecycle).
- `Tests/InnoRouterMacrosBehaviorTests/MacroPerformanceTests.swift`
  with 10/50/100-case `@Routable` fixtures — runtime CasePath
  baseline and a coarse 1,000-iteration budget at N=100.
- `Tests/InnoRouterTests/Concurrency/StoreRaceStressTests.swift`
  — TaskGroup race stress for path consistency, event fan-out
  under burst, and multi-subscriber parity on `NavigationStore`.
- `NavigationExecutionResult<R>` protocol unifying the shared
  shape of `NavigationBatchResult` and `NavigationTransactionResult`.
  `NavigationTransactionResult.isSuccess` is added as a thin alias
  for `isCommitted` to satisfy the protocol's predicate.
- `NavigationStore.pathBinding(policy:)` overload — per-call
  override of `NavigationPathMismatchPolicy` for one binding
  site without flipping the store-wide configuration.
- `ModalDismissalReason.middlewareCancelled(reasonDescription:)`
  case so middleware-driven dismissals are no longer bucketed
  into `.systemDismiss` for analytics.
- Stable error codes (`InnoRouterMacro.E001` / `E002` / `E003`)
  prefixed onto every `@Routable` / `@CasePathable` diagnostic
  message, so build logs and localized release notes stay
  searchable across translations.
- `.changes/` directory holding per-PR changelog fragments;
  contributors drop `<slug>.<category>.md` files instead of
  editing this file directly.
- `AsyncNavigationMiddleware<R>` protocol (in `InnoRouterCore`)
  and `AsyncNavigationMiddlewareExecutor<R>` (in
  `InnoRouterSwiftUI`) — opt-in async middleware slot layered
  around the synchronous `NavigationStore.execute(_:)`. Stages
  run in insertion order on `willExecute`, reverse order on
  `didExecute`. Cancellation short-circuits with a typed reason.
  The synchronous engine and `NavigationStore.execute(_:)` keep
  their existing shape; apps that don't add async middleware see
  no behavioral difference.
- `ModalQueueCancellationPolicy<M>` and
  `ModalStoreConfiguration.queueCancellationPolicy` — controls
  what happens to `ModalStore.queuedPresentations` when a
  `ModalMiddleware` cancels a command. Defaults to `.preserve`
  (historical 4.x behaviour). `.dropQueued` and
  `.custom((command, reason) -> Action)` give standalone
  ModalStore users the same kind of queue policy that previously
  only flowed through `FlowStore.QueueCoalescePolicy`.
- `NavigationStore.commands(for: NavigationIntent<R>) ->
  [NavigationCommand<R>]` — projects an intent into the concrete
  command plan that `send(_:)` would execute. `send(_:)` is now
  implemented in terms of this projection so the two surfaces
  cannot drift.
- `NavigationPathReconciling<R>` protocol describing the
  contract the framework `NavigationPathReconciler<R>` (now
  public) satisfies. `NavigationStoreConfiguration.pathReconciler`
  injects a custom conformance — the framework default applies
  when none is supplied.
- `LifecycleSignals` value type — bag of optional
  parent-cancel / teardown callbacks shared across coordinator
  types.
- `LifecycleAware` capability protocol — `ChildCoordinator`
  inherits it unconditionally; `Coordinator`, `FlowCoordinator`,
  and `TabCoordinator` opt in case-by-case to expose teardown
  hooks through host code.
- `FlowStateReading<R>` protocol — public read-only projection of
  FlowStore-shaped state (`path`, `navigationPath`,
  `currentModalRoute`, `currentModalPresentation`,
  `hasModalTail`). Replaces the `@_spi(FlowStoreInternals)`
  peephole for read-only access.

### Changed

- `FlowStore.isApplyingInternalMutation` is now backed by a depth
  counter (`mutationDepth: Int`) and surfaced as a computed
  `Bool`. Reverse-sync guards keep the same shape, but nested
  invocations no longer silently restore the flag on the inner
  `defer`. A release-mode `precondition` on counter underflow
  catches imbalances loudly.
- `scripts/principle-gates.sh` gains inline section comments
  documenting each gate's purpose, failure signal, and local
  repro command.
- `RELEASING.md` documents the toolchain pin matrix (minimum
  Xcode, bundled Swift host, package floor, swift-syntax pin,
  Apple platform floor) in one table.
- `.swiftlint.yml` enables `file_length` (warning 1800 / error
  2200) and `type_body_length` (warning 730 / error 900) as
  catastrophic-regression guardrails. Thresholds sit just above
  today's largest fixtures so no current file fails.
- `SceneStore`, `SceneHost`, and the rest of the visionOS spatial
  scene surface (`SceneAnchor`, `ScenePresentation`,
  `SceneIntent`, `SceneEvent`, `SceneRegistry`,
  `SceneDeclaration`) are documented as **experimental** —
  outside the 4.x SemVer additive guarantee. Apps adopting them
  should pin to an exact release until the surface graduates.
  README "Platform support" / "Choosing the right surface"
  tables carry a `⚠ experimental` marker.
- README "Imports" table is rewritten to recommend
  `InnoRouterEffects` (the umbrella) as the canonical import for
  app-boundary execution helpers. The split products
  (`InnoRouterNavigationEffects`, `InnoRouterDeepLinkEffects`)
  stay available for source compatibility and fold into the
  umbrella in a future major.
- `ChildCoordinator` requires `lifecycleSignals: LifecycleSignals`.
  The protocol inherits from the new `LifecycleAware` capability
  protocol. Adopters add the stored property; the protocol
  cannot supply a default for a stored requirement.
  `Coordinator.push(child:)` fires both
  `lifecycleSignals.fireParentCancel()` and the existing
  `parentDidCancel()` hook, so adopters can choose closure-style
  or override-style teardown.

### Fixed

- `FlowDeepLinkPipeline` now preserves typed input-limit rejections
  when its matcher has stricter `DeepLinkInputLimits` than the
  pipeline itself. URLs rejected by matcher limits surface as
  `.rejected(.inputLimitExceeded(...))` instead of falling through to
  `.unhandled`, so security and telemetry branches can distinguish
  malformed input from unmatched routes.
- `Tests/InnoRouterMacrosBehaviorTests/README.md` now describes the
  Swift 6.3 tuple-subscript coverage gap accurately. The suite has no
  Swift Testing `.disabled` cases; the remaining unexecutable probes
  are documented next to the affected `RoutableBehaviorTests` and
  `CasePathableBehaviorTests` tuple `[case:]` call sites.

### Refactor

- `Sources/InnoRouterMacrosPlugin/CasePathMemberBuilder.swift`
  (237 LOC) is split by responsibility into three files:
  `CasePathEnumIteration.swift` (syntax tree → CasePathEnumCase),
  `CasePathMemberGeneration.swift` (CasePathEnumCase → rendered
  source string), and `CasePathMemberBuilder.swift` (entry +
  diagnostics + orchestration). Helpers widen from `private` to
  `internal` so the orchestrator can reach them across files;
  nothing escapes the InnoRouterMacrosPlugin module. No public
  surface change.
- `Sources/InnoRouterSwiftUI/NavigationStore.swift` (807 LOC)
  is split into `NavigationStore.swift` core (~640 LOC) plus
  `+Intent`, `+Binding`, `+Middleware` extension files.
- `Sources/InnoRouterSwiftUI/ModalStore.swift` (879 LOC) is
  split into core (~810 LOC) plus `+Middleware` and `+Binding`
  extension files.
- `Sources/InnoRouterSwiftUI/FlowStore.swift` (810 LOC) gets
  the public `send(_:)` / `apply(_:)` dispatch wrappers moved to
  `FlowStore+Public.swift`. Deeper splits of the dispatch spine
  remain in the core for now.

### Internal

- `Package.swift` excludes `Examples/README.md` and
  `ExamplesSmoke/README.md` from per-file example targets so
  `-warnings-as-errors` does not surface SwiftPM's "unhandled
  file" warning on the new contributor docs.

### Removed

- `@_spi(FlowStoreInternals)` peephole removed.
  `FlowStore.navigationStore` and `FlowStore.modalStore` are plain
  `internal` properties. Adopters that imported
  `@_spi(FlowStoreInternals) [@testable] import InnoRouterSwiftUI`
  switch to plain `@testable import` for tests, or to the public
  `FlowStateReading` protocol for read-only access from production
  code. Mutations should flow through `FlowStore.send(_:)` /
  `FlowStore.apply(_:)`.

### Pre-OSS adoption baseline (folded in)

The remaining sub-sections list the 4.0.x → 4.1.0 surface
changes that originally targeted a standalone "4.1.0 baseline"
release. They ship in the same tag as the routing-surface
refresh above.

#### Added

- `DeepLinkInputLimits` caps absolute URL length, path segment count,
  and query item count before matching. Push-only and flow pipelines
  now surface limit violations as
  `DeepLinkRejectionReason.inputLimitExceeded`.
- `FlowStore.init(validating:configuration:)` validates initial
  `[RouteStep]` input and throws `FlowPlanValidationError` instead of
  relying on the compatibility initializer's empty-path fallback.
- `FlowDeepLinkMatcher.init(strict:logger:inputLimits:mappings:)` now matches
  `DeepLinkMatcher` strict diagnostics parity for both builder and
  array-based flow mapping construction.
- Deep-link pattern diagnostics now reject invalid parameter names
  (`^[A-Za-z_][A-Za-z0-9_]*$`) in both push-only and flow strict
  matchers.
- `NavigationPlan.validationFailure(on:)` / `canExecute(on:)` let
  push-only effect and coordinator boundaries dry-run a plan before
  execution.
- `ModalEvent.replaced(old:new:)` and `ModalStoreConfiguration.onReplaced`
  expose first-class modal replacement lifecycle semantics.
- `NavigationEffectHandler.events` emits command, batch, and
  transaction outcomes through `AsyncStream`.
- `resumePendingDeepLinkIfAllowed` has throwing async overloads for
  auth probes that can fail before producing a boolean decision.
- Public localized description surfaces were added to user-visible
  rejection and cancellation reason enums.
- `AnyNavigationTelemetrySink`, `AnyModalTelemetrySink`, and
  `AnyFlowTelemetrySink` provide structured telemetry adapters;
  OSLog-backed sinks remain available as defaults when a `Logger` is
  supplied.
- `StateRestorationAdapter` snapshots and restores navigation stacks
  and flow plans while reporting decode/apply failures instead of
  silently falling back to an empty state.
- Macro snapshot coverage now locks down keyword associated-value
  labels, availability propagation, and empty-enum diagnostics.
- The performance smoke report now includes resident memory footprint
  when the platform can provide it.

#### Changed

- Local and CI DocC preview checks now pass `--skip-latest` so preview
  validation does not spend work generating the release-only `latest/`
  alias.
- `DeepLinkMatcherConfiguration` emits diagnostics in Release when a
  logger is installed, so duplicate, shadowing, non-terminal wildcard,
  and invalid-parameter diagnostics are visible in release gates.
- `@EnvironmentNavigationIntent`, `@EnvironmentModalIntent`, and
  `@EnvironmentFlowIntent` now expose `@MainActor @Sendable` intent
  closures rather than public dispatcher objects.
- `NavigationStoreConfiguration`, `ModalStoreConfiguration`, and
  `FlowStoreConfiguration` now accept structured telemetry sinks
  directly. `logger` remains as the default OSLog adapter input and
  internal trace logger.
- Core middleware remains a synchronous-only contract; async policy
  checks belong in effect handlers such as `executeGuarded` and
  pending deep-link replay guards.
- `swiftformat` and `swiftlint` are wired as check-only source gates
  when those tools are present locally or in CI.

#### Fixed

- `DeepLinkMatcherStrictError.init(diagnostics:)` no longer traps when
  called with an empty diagnostics array. Strict matcher initializers
  still only throw it after producing diagnostics, but the public error
  type is now safe for custom validators and focused tests to construct.
- Push-only deep-link handlers and coordinator bridges no longer
  execute obviously invalid `NavigationPlan`s.
- Flow modal replacement now emits `.replaced` before the replacement
  command interception and before the projected flow path update.
- `@CasePathable` generation is more stable for labeled associated
  values that use Swift keywords.

#### Removed

- `NavigationIntent.resetTo` is removed. Use
  `NavigationIntent.replaceStack` for full-stack replacement.
- `AnyNavigationIntentDispatcher`, `AnyModalIntentDispatcher`,
  `AnyFlowIntentDispatcher`, and their public dispatching protocols
  are removed. Environment intent wrappers now return direct closures.
- `NavigationEffectHandler.lastResult` and `lastBatchResult` are
  removed. Subscribe to `NavigationEffectHandler.events` instead.

## 4.0.0 - 2026-04-28

4.0.0 is InnoRouter's first OSS release and the start of the public
SemVer compatibility line. Earlier private/internal snapshots are not
part of the OSS release history. This release opens the public surface
with typed navigation, modal, flow, scene, deep-link, macro, and
host-less testing APIs, plus the release/documentation gates needed to
keep that surface stable.

The notes below call out the initial OSS surface and the compatibility
details that matter for teams that tested pre-OSS snapshots.

### Initial OSS surface

- Typed navigation, modal, and flow stores with explicit command,
  batch, transaction, and intent execution.
- SwiftUI-first hosts across Apple platforms, including visionOS
  scene/window/volumetric/immersive routing through `SceneStore`.
- App-boundary deep-link planning through push-only and composite
  `FlowDeepLinkPipeline` APIs, with pending replay and state
  persistence helpers.
- `@Routable` / `@CasePathable` macros, `InnoRouterTesting`
  host-less test stores, tutorial-grade DocC, example smoke targets,
  and release gates for public API baselines, documentation snippets,
  platform builds, and performance smoke.

### Pre-OSS compatibility notes

- `@Routable` and `@CasePathable` infer the access level of every
  generated `Cases` table, `is(_:)`, `[case:]`, and case
  `static let` member from the enclosing enum. `internal` and
  `private` enums no longer leak public CasePath surface. Each
  case `static let` also receives any `@available(...)`
  attribute attached to the enum case. Mark the enclosing enum
  `public` if a consumer relies on the wider surface; an opt-in
  `@Routable(visibility: .public)` argument is on the v4.x
  roadmap. See `Articles/Guide-MacroVisibility.md` for the full
  migration matrix.
- `@Routable` / `@CasePathable` now emit an `error`-severity
  diagnostic (was `warning`) when applied to an enum with zero
  cases. The macro produces no members on an empty enum, so the
  warning was easy to miss in noisy build logs and turned the
  macro into a silent no-op. Builds now fail at the macro site
  with "add a case or remove the macro" guidance.
- `DeepLinkMatcherDiagnosticsMode.strict` is removed. The strict
  diagnostic-promotion path was always reachable only through the
  throwing `DeepLinkMatcher.init(strict:logger:inputLimits:mappings:)`
  initializer; configuring `.strict` on the non-throwing
  `init(configuration:mappings:)` previously trapped at runtime
  via `preconditionFailure`. The case removal makes the misuse
  unrepresentable. `.disabled` and `.debugWarnings` remain.
- `FlowStore.navigationStore` and `FlowStore.modalStore` are now
  `@_spi(FlowStoreInternals)` instead of public API. `FlowHost`,
  focused internal tests, and examples that must compose the inner
  hosts can opt into the SPI import; app code should route through
  `FlowStore.path`, `send(_:)`, `apply(_:)`, `events`, and
  `intentDispatcher` so FlowStore invariants cannot be bypassed.
- `DeepLinkPattern` now treats `*` as terminal-only. Patterns such
  as `/api/*/users` no longer match as "wildcard from here to the
  end"; matchers surface `.nonTerminalWildcard(pattern:index:)` in
  debug / strict diagnostics so ambiguous authoring fails before
  release.
- Middleware-mutation-during-willExecute semantics: when a
  middleware calls `registry.add(_:)` / `remove(_:)` from its own
  `willExecute`, the same set of middlewares that ran `willExecute`
  receives `didExecute` (or `discardExecution`) for the same
  command — the live `entries` snapshot at intercept time is
  authoritative. Previously, mid-flight inserts could deliver a
  one-sided `didExecute` to a middleware that had not run
  `willExecute`, and removes could orphan `didExecute` for a
  middleware that did. Internal API change:
  `NavigationMiddlewareRegistry.InterceptionOutcome.participantCount`
  is now `participants: [AnyNavigationMiddleware<R>]` (mirror for
  `AnyModalMiddleware`); `NavigationExecutionJournal` and
  `ModalExecutionJournal` carry the snapshot through their
  preview / transaction / discard paths.

### Added

- `EnvironmentMissingPolicy.assertAndLog` is a third policy
  alongside `.crash` and `.logAndDegrade`. It traps with
  `assertionFailure` in Debug while degrading to a logged no-op
  dispatcher in Release, fitting TestFlight / pre-launch ship
  configs that need loud development signal without paging
  users on a stray missing host.
- `FlowPlan(validating:)` (throwing initializer),
  `FlowPlan.validate(_:)` (public static validator), and
  `FlowPlanValidationError` (`tooManyModals`, `modalNotAtTail`)
  let deep-link planners and state-restoration drivers surface
  invariant violations up front. `FlowPlan` Codable decode runs
  the same validator and converts violations into
  `DecodingError.dataCorruptedError`.
- `QueueCoalescePolicy<R>` enum + `FlowStoreConfiguration.queueCoalescePolicy`
  setting. When a `NavigationStore` middleware cancels a
  flow-level command, the policy decides what happens to the
  modal queue: `.preserve` (default, pre-4.0 behaviour) keeps
  the queue intact; `.dropQueued` dismisses the active modal
  and drops every queued presentation (useful for
  `replaceStack` flows); `.custom(_:)` hands control to a
  closure for per-intent decisions. See
  `Articles/Guide-QueueCoalescePolicy.md`.
- `DebouncingNavigator<N: NavigationCommandExecutor, C: Clock>`
  closes the long-deferred `.debounce` roadmap item with a wrapping
  navigator: `debouncedExecute(_:)` schedules the latest command
  after a quiet window and cancels superseded ones. Generic over
  `Clock` for deterministic test injection.
- `DeepLinkParameterValue` and typed `DeepLinkParameters`
  accessors: `firstValue(forName:as:)` and `values(forName:as:)`
  parse captured path / query values into `String`, integer and
  floating-point numeric types, `Bool`, and `UUID`. Invalid values
  return `nil` or are skipped from the typed array, leaving the
  existing string accessors unchanged.
- `DeepLinkMatcherDiagnostic.nonTerminalWildcard(pattern:index:)`
  is emitted by both push-only and flow deep-link matchers when a
  wildcard is not the final pattern segment.
- `NavigationStoreConfiguration` / `ModalStoreConfiguration` /
  `FlowStoreConfiguration` stored properties are now
  `public var` so call sites can patch individual callbacks
  after construction without re-stating every parameter.
- `FlowStore.intentDispatcher` is now exposed as a cached
  property mirroring `NavigationStore` and `ModalStore`. Hosts
  no longer allocate a fresh `AnyFlowIntentDispatcher` on every
  body evaluation.
- `Tests/InnoRouterTests/ConfigurationMutationTests.swift`
  covers the `var` patchability of all three configuration
  structs.
- `Tests/InnoRouterTests/QueueCoalescePolicyTests.swift` covers
  the three policy paths (`.preserve` / `.dropQueued` /
  `.custom`) plus the caller-side invariant exclusion.
- `Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/Migration-FromTCA.md`
  is a step-by-step guide for migrating navigation from TCA
  (`StackState`, `@Presents`, `NavigationStackStore`) to
  InnoRouter (`NavigationStore` + `ModalStore` + `FlowStore`),
  with side-by-side reducer and view samples.
- `Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/CaseStudy-OnboardingFlow.md`
  is a representative composition showing how `FlowStore` +
  `ChildCoordinator` + `FlowPlan` + middleware compose into a
  12-screen onboarding sequence with deep-link rehydration and
  entitlement gating.
- `release.yml` accepts `workflow_dispatch` with `tag` and
  `prerelease` inputs so `<version>-(rc|beta).<n>` tags can be
  published as GitHub pre-releases.
- `scripts/check-docs-code-blocks.sh` requires every Swift fenced
  block in repository Markdown files (`*.md`) to declare either
  `swift compile` or `swift skip <reason>`. Compile-marked snippets
  are typechecked against the local package through a temporary
  SwiftPM target, and `principle-gates.sh` now runs the repo-wide
  check.
- `Docs/macro-dependency-cost.md`, `Examples/SampleAppExample.swift`,
  `ExamplesSmoke/SampleAppSmoke.swift`, the sequence/batch/transaction
  DocC guide, and OSS metadata files (`CONTRIBUTING.md`,
  `SECURITY.md`, `CODE_OF_CONDUCT.md`) round out adoption evidence
  and examples for the current public surface.
- `scripts/lint-source-gates.sh`,
  `scripts/check-changelog-sync.sh`, the `changelog-sync` workflow
  job, weekly Dependabot config, and platform runtime tests for tvOS /
  watchOS make release drift visible before tags are cut.
- `Docs/IntentSelectionGuide.md` names the four request types
  (`NavigationCommand` / `ModalCommand` / `*Intent` / `FlowPlan`)
  side by side with imperative-vs-view-layer guidance,
  `NavigationIntent` vs `FlowIntent` decision boundary, and three
  pitfalls that come up most often in code review. The README
  "Choosing the right surface" section gains a quick decision
  flowchart and links the guide.
- `NavigationCommand.whenCancelled` doc-comment now spells out
  the broadcaster contract: at most one `.changed` event for the
  net transition, with no leakage of intermediate states reached
  during a partially-applied primary that is later rolled back.
- `Tests/InnoRouterTests/MiddlewareParticipantSnapshotTests.swift`
  locks in the in-flight middleware add/remove invariant on both
  `NavigationMiddlewareRegistry` and `ModalMiddlewareRegistry`.
- `Tests/InnoRouterTests/WhenCancelledBroadcastTests.swift` locks
  in the `.whenCancelled` broadcaster ordering contract across
  primary success, partial-sequence rollback, middleware-cancelled
  primary, and zero-net-change paths.
- `Tests/InnoRouterTests/EventBroadcasterLeakTests.swift` smokes
  the `EventBroadcaster` subscriber lifecycle so bulk subscribe /
  cancel churn drains back to zero and concurrent subscribers
  each receive every broadcast in order.

### Changed

- `DebouncingNavigator` now logs sleep failures through a new
  `os_log` `debouncing-navigator` category before tripping
  `assertionFailure`, so Release builds leave an audit trail
  even when the trap is compiled out.
- `release.yml`, `docs-ci.yml`, and `performance-smoke.yml` now use
  the same pinned Xcode setup path as `principle-gates.yml` and
  `platforms.yml`, keeping tag validation, DocC builds, and
  performance smoke checks on the gated CI toolchain.
- `README.md` reframes the iOS 18+ / Swift 6.2 floor as the
  Sendable / strict-concurrency feature it actually buys, with
  a posture comparison against peers shipping on iOS 13+ that
  rely on `@preconcurrency` / `@unchecked Sendable`.
- `scripts/check-public-api.sh` source-level Sendable contracts
  for the three configuration structs match `public var`
  instead of `public let`, tracking the v-to-l switch.
- `swift-syntax` is now pinned with
  `.upToNextMinor(from: "603.0.1")`, matching `Package.swift` and
  `Package.resolved`. Swift 6.2 remains the package floor; the current
  host validation is clean against Swift 6.3.
- `NavigationStore`, `ModalStore`, and `FlowStore` split their
  static telemetry / path-helper helpers into sibling
  `+TelemetryAdapters.swift` / `+PathHelpers.swift` extensions so
  the primary class definitions stay focused on the `Observable`
  storage and execution surface. Public-API baseline diff = 0
  for the splits.
- `NavigationEnvironmentStorage`, `ModalEnvironmentStorage`, and
  `FlowEnvironmentStorage` setters now distinguish a benign same-owner
  environment update from a different-owner overwrite at the same
  route-type slot, surfacing duplicate host registration mistakes.
- `NavigationPathMismatchPolicy` and
  `NavigationStoreConfiguration.pathMismatchPolicy` source docs now
  spell out the default `.replace` operating stance and when to use
  `.assertAndReplace`, `.ignore`, or `.custom`.
- `EventBroadcaster.subscriberCount` is documented as an
  eventually-consistent test probe after stream cancellation because
  `AsyncStream.Continuation.onTermination` hops cleanup back to the
  main actor.

### Fixed

- `FlowStore.events` now wraps inner navigation and modal callbacks
  synchronously, so `.navigation(...)` / `.modal(...)` events cannot be
  overtaken by flow-level `.pathChanged` or `.intentRejected` events.
- `@Routable` and `@CasePathable` preserve backtick-escaped Swift
  keyword cases in generated `CasePath` members.
- `FlowStore.path` now resyncs when the inner `ModalStore` swaps its
  current presentation through `replaceCurrent(_:style:)`, including
  via typed `binding(case:style:)`.
- Middleware `participantCount` prefix-iteration corruption: see the
  pre-OSS compatibility note above. `NavigationMiddlewareRegistry` and
  `ModalMiddlewareRegistry` now operate on a frozen participants
  snapshot.
- Trace metadata hot-path: `InternalExecutionTrace.withSpan`'s
  `metadata` parameter is now `@autoclosure`, and the function
  short-circuits when no recorder is installed. `String(describing:)`
  on every command/preview argument is no longer evaluated for the
  99% of installs that do not register a `Logger` or telemetry
  recorder.
- `NavigationStore.executeBatch` and `executeTransaction` now
  `reserveCapacity(commands.count)` on their per-command result
  arrays so a 64+ command batch does not pay the doubling-grow
  reallocation cost.
- `FlowStore.withInternalMutation` carries a DEBUG-only assertion
  against reentrant invocation. The flag's "set → run → restore"
  pattern is correct only under MainActor + synchronous body
  execution; a future async path would silently misbehave at the
  reverse-sync guards. Production keeps the existing zero-cost flag
  behaviour.

### Future backlog

The following review items remain intentionally outside the 4.0 GA
surface. They are internal or low-priority follow-ups without a
promised release version:

- `MiddlewareRegistryCore` generic extraction — DRY refactor of the
  decalcomania across `NavigationMiddlewareRegistry` and
  `ModalMiddlewareRegistry`. Internal-only refactor, no API impact.
- `FlowStore.path` projection caching with invalidation token —
  amortizes per-mutation array reconstruction in deep stacks.
- `FlowStore` decomposition into `FlowDispatcher` / `FlowProjection`
  / `FlowReverseSync` — internal SRP cleanup; the public facade
  (`send` / `apply` / `events` / `intentDispatcher`) remains.
- `Package.swift` example boilerplate cleanup via SPM 5.9+ resource
  enumeration (low priority — current `exampleTarget(...)` helper
  already collapses adds to two edits).
