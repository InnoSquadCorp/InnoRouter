# InnoRouterDeepLink

Pattern matching, pipeline planning, and pending deep-link handling for InnoRouter.

## Overview

`InnoRouterDeepLink` turns URLs into typed routes or complete flow plans,
then validates and coordinates their execution.

This module owns:

- `DeepLinkMatcher`
- `DeepLinkMapping` and `DeepLinkParameters`
- `DeepLinkMatcherConfiguration`
- `DeepLinkPipeline`
- `DeepLinkDecision`
- `PendingDeepLink`
- `NavigationPlan`
- `DeepLinkMatcher<FlowPlan<R>>` + `FlowDeepLinkPipeline` for
  composite flows (push prefix + modal terminal step).

The key idea is that deep links are not executed ad hoc. They are matched, validated, authorized, and planned first.

## Topics

### Essentials

- <doc:Matcher-and-Diagnostics>
- <doc:Pipeline-and-Pending-Deep-Links>

### Tutorials

- <doc:Tutorial-FlowDeepLinkPipeline>
