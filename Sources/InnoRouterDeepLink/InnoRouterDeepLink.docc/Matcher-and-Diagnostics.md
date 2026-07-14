# Matcher and diagnostics

@Metadata {
  @PageKind(article)
}

`DeepLinkMatcher` is the URL-pattern front door for route and `FlowPlan` deep-link outputs.

## Pattern model

Patterns support:

- literal segments
- named parameters such as `:id`
- terminal wildcard `*`

This keeps matching simple and predictable for app routing.

Wildcards are terminal-only. A pattern like `/api/*/users` is invalid:
it produces a `.nonTerminalWildcard(pattern:index:)` diagnostic and does
not match runtime paths.

Captured values stay available as strings through `firstValue(forName:)`
and `values(forName:)`. For common scalar types, use the typed overloads:

```swift skip doc-fragment
let id = parameters.firstValue(forName: "id", as: UUID.self)
let page = parameters.firstValue(forName: "page", as: Int.self)
let selectedTags = parameters.values(forName: "tag", as: String.self)
```

## Match precedence

Match precedence remains declaration-order based.

That means:

- earlier patterns win
- diagnostics do not change runtime behavior
- ordering is still part of the matcher contract

## Diagnostics

`DeepLinkMatcherConfiguration` can surface diagnostics for common authoring mistakes:

- duplicate patterns
- wildcard shadowing
- non-terminal wildcards
- invalid parameter names; parameter names must match
  `^[A-Za-z_][A-Za-z0-9_]*$`
- parameter-heavy patterns that subsume more specific later patterns

Diagnostics are available for every matcher output. They are intended
to catch ambiguous authoring early without changing the matcher’s
runtime semantics.

For release-readiness gates, use `DeepLinkMatcher(strict:)` with either
a route or `FlowPlan<R>` output. Strict initializers throw
`DeepLinkMatcherStrictError` with
the full diagnostic list instead of only logging warnings, and accept
the same `DeepLinkInputLimits` guardrails used by non-strict matchers.

## Input limits

`DeepLinkInputLimits` guards runtime URLs before matching. Configure it
on `DeepLinkMatcherConfiguration`, `DeepLinkPipeline`, or
`FlowDeepLinkPipeline` to cap absolute URL length, path segment count,
and query item count. Direct matcher calls still return `nil` because
their public contract is optional. Pipeline and effect-handler paths
surface limit violations as typed
`DeepLinkRejectionReason.inputLimitExceeded` rejections instead of
"no match" outcomes.
