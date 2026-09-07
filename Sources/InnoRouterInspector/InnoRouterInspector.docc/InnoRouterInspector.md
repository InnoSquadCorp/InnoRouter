# InnoRouterInspector

A bounded, payload-safe navigation timeline for development and diagnostics.

## Overview

`InnoRouterInspector` is an opt-in product that observes the canonical
`RouterStore` event stream. It does not intercept, mutate, or replay routing
operations.

Create a ``InnoRouterInspector/RouterInspectorRecorder``, attach the store that
should be observed, and retain each
``InnoRouterInspector/RouterInspectorSubscription`` for the desired capture
lifetime. Default formatters retain operation names, outcomes, styles, and
counts while excluding route payload descriptions. A custom
``InnoRouterInspector/RouterInspectorFormatter`` is the explicit opt-in point
for app-specific details.

``InnoRouterInspector/RouterInspectorView`` presents the bounded timeline with
domain filters, pause/resume, rejection breakpoints, bookmarks, arbitrary A/B
comparison, native JSON snapshot/bundle import, bundle export, step controls,
clear, and entry detail.
When the app also imports `InnoRouterTesting`, pass a
``InnoRouterInspector/RouterInspectorScenarioController`` created by its
standard `routerScenario(store:)` adapter. This adds explicit start, progress,
stop, completeness, and raw fixture import/export. Raw fixture controls are
visibly separate because route payloads may be present.
Start, stop, and import failures use
``InnoRouterInspector/RouterInspectorScenarioFailure`` and localized generic
summaries. Arbitrary decoder or application error descriptions are not shown,
and a failed import clears any stale raw fixture that could otherwise be shared.
``InnoRouterInspector/RouterInspectorSnapshot`` is a value-only, Codable export
suitable for attaching to a bug report after the app has applied its own
retention and disclosure policy.

``InnoRouterInspector/RouterInspectorDiagnosticBundle`` wraps that redacted
snapshot with its InnoRouter release and Apple platform identity. The recorder
encodes bundles with stable JSON key and bookmark ordering. Default formatters
remain payload-safe; applications that install custom formatters must review
the app-owned metadata before sharing a bundle. `importDiagnosticBundle(from:)`
reopens the session and returns its original environment metadata. Unsupported
format versions fail before decoding entries, and failed imports preserve the
current timeline and bookmarks.

The recorder can import that export with an explicit replace or append policy.
``InnoRouterInspector/RouterInspectorPlayback`` steps through an imported
session without a live store, while
``InnoRouterInspector/RouterInspectorComparison`` compares final states across
sessions or any two captured states in one session. Entries include correlated
elapsed and transition-duration metadata. All comparisons operate on
payload-redacted trees, and older snapshots without bookmarks remain decodable.
Byte and entry limits apply to both snapshot and bundle imports before entry
decoding. Duplicate envelope keys are rejected, escaped keys are recognized,
and orphan bookmarks are discarded. Replacing a timeline clears live timing
correlation so imported sessions cannot inherit durations from earlier work.

For a macro router declared with `inspectorCatalog: true`,
``InnoRouterInspector/RouterInspectorDeepLinkView`` is an opt-in URL workbench.
``InnoRouterInspector/RouterInspectorDeepLinkAnalyzer`` projects the generated
catalog, ordered attempts, and terminal failure without route payload values or
navigation side effects. Its preview API uses the pure reducer for a redacted
target diff. The `store:` view initializer exposes execution separately; only
that explicit action resolves the URL and submits through normal policies.
The default share action uses only the structural decision and declared route
patterns, never the entered URL. Execution status is structured and localized,
and leaving the workbench cancels only its owned execution task.

## Topics

### Capture

- ``InnoRouterInspector/RouterInspectorRecorder``
- ``InnoRouterInspector/RouterInspectorSubscription``
- ``InnoRouterInspector/RouterInspectorFormatter``

### Timeline values

- ``InnoRouterInspector/RouterInspectorEntry``
- ``InnoRouterInspector/RouterInspectorEventDescription``
- ``InnoRouterInspector/RouterInspectorDomain``
- ``InnoRouterInspector/RouterInspectorOutcome``
- ``InnoRouterInspector/RouterInspectorSnapshot``
- ``InnoRouterInspector/RouterInspectorDiagnosticBundle``
- ``InnoRouterInspector/RouterInspectorPlayback``
- ``InnoRouterInspector/RouterInspectorComparison``
- ``InnoRouterInspector/RouterInspectorImportPolicy``
- ``InnoRouterInspector/RouterInspectorStateTree``
- ``InnoRouterInspector/RouterInspectorStateDiff``

### User interface

- ``InnoRouterInspector/RouterInspectorView``
- ``InnoRouterInspector/RouterInspectorDeepLinkView``
- ``InnoRouterInspector/RouterInspectorDeepLinkAnalyzer``
- ``InnoRouterInspector/RouterInspectorScenarioController``
- ``InnoRouterInspector/RouterInspectorScenarioStatus``
- ``InnoRouterInspector/RouterInspectorScenarioFailure``
