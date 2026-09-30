# Inspector localization

The optional `InnoRouterInspector` product includes 66 interface strings in
English and 15 translated languages. These strings were authored and reviewed
entry by entry against the actual controls and state transitions, not generated
by a translation script. This is not a claim of native-speaker approval in
every language.

## Supported languages

English (`en`), Korean (`ko`), Japanese (`ja`), Simplified Chinese (`zh-Hans`),
Traditional Chinese (`zh-Hant`), Spanish (`es`), French (`fr`), German (`de`),
Italian (`it`), Brazilian Portuguese (`pt-BR`), Russian (`ru`), Arabic (`ar`),
Hindi (`hi`), Indonesian (`id`), Vietnamese (`vi`), and Thai (`th`).

The source of truth is
[`Localizable.xcstrings`](../Sources/InnoRouterInspector/Localizable.xcstrings).
Every entry has a translator comment describing its functional context.
English is the source language and fallback, not an additional generated
translation. Regional locales use Foundation's language/script matching;
tests explicitly cover Korean/Japanese regions and Simplified/Traditional
Chinese script selection. Unsupported languages fall back to English.

Xcode compiles the catalog into localized bundles. Toolchains such as SwiftPM
6.3 that copy the catalog unchanged use an internal, cached reader for the same
plain string values. No generated translation file or duplicated wording is
maintained. Both resource paths are checked against all 990 reviewed values.

## Language selection

`RouterInspectorView` and `RouterInspectorDeepLinkView` read SwiftUI's `locale`
environment. Without an override, they use the environment supplied by the
host app. An app can apply `.environment(\.locale, Locale(identifier: "ko"))`
to either Inspector view. Labels and existing status/failure messages update
while the view remains mounted; the recorder, selection, and live store are
not reset. Timeline timestamps use the same locale.

Locale and layout direction are separate environment values. When forcing an
Arabic preview inside a left-to-right host app, also apply
`.environment(\.layoutDirection, .rightToLeft)`; do not expect a locale override
alone to change layout direction. Host-app language availability and native
file/share panels remain the host's responsibility. The package does not
change device preferences or localize the rest of the app.

Changing locale alone preserves the native containers. A layout-direction
change recreates the workbench's native Form and, on split-view platforms, the
timeline's native split/list boundary to avoid stale mirrored geometry. Stable
outer containers retain the parent's tab identity. Recorder, scenario, filters,
selection, comparison, URL input, and execution ownership remain outside the
recreated boundaries. Native focus or scroll position may reset on a direction
change; this is not a reset of captured navigation data or in-flight execution.

## Translation boundaries

Translate Inspector-owned labels, accessibility text, recording/execution
statuses, and generic payload-free failure messages. Keep event names,
domain/outcome identifiers, diagnostic decisions, metadata keys, route patterns,
structural trees/diffs, and JSON stable across languages so bug reports and
filters remain comparable. App-provided formatter content and successful
scenario summaries are displayed verbatim; the app owns their localization.

The controller's public `summary` is a snapshot string. The native view uses
the structured `failure` category to render failure text in its current locale
instead of reusing that snapshot. Custom UIs should make the same distinction.

## Meaning that must be preserved

- **Recording:** capture navigation scenario events, not screen, video, or
  audio. Korean uses `기록`, not `녹화`.
- **Stop recording:** finish capture and retain its result. **Cancel
  recording:** discard raw capture data; this does not undo navigation.
- **Complete / incomplete:** whether the captured fixture contains the
  information needed for replay. Incomplete is not a synonym for failed or
  currently recording.
- **Pause / resume:** control timeline capture. Do not imply pausing the live
  router or replaying a scenario.
- **Deferred / rejected / unresolved:** respectively pending a policy decision,
  declined by routing policy, and a URL that did not resolve to a route.
- **Pure reducer preview:** calculate a structural transition without live
  execution. `Execute` is a separate, explicit action.
- **Previous captured state / target difference:** compare recorded or
  proposed state trees, not a navigation Back command.
- **Raw fixture:** replay test data that may include route payloads. Keep its
  privacy warning separate from the default payload-redacted diagnostic export.

## Maintenance and evidence

Review translations directly in the catalog, comparing each value to its
comment and the actual feature. Avoid mass word replacement: the same English
word can have different meanings in capture, execution, and comparison.

`python3 scripts/check-inspector-localization.py` performs read-only validation
of duplicate keys, coverage, translation state, whitespace, comments, and
unexpected formatting substitutions. It is included in the source lint gate.
It neither produces translations nor proves their semantic quality.

`RouterInspectorLocalizationTests` checks all 990 translated values against
the compiled package resources, English and unsupported-language fallback,
regional matching, and repeated language changes. The iPad UI probe exercises
English, Korean, German, and Arabic on the same mounted views, including
cancellation, recording controls, long labels, and right-to-left layout.
Passing those tests does not prove native-speaker quality, every-language
layout on every device, or real-device VoiceOver behavior. Track those
boundaries explicitly rather than calling resource coverage full UI coverage.
