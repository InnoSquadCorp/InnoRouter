# Pipeline and pending deep links

@Metadata {
  @PageKind(article)
}

`DeepLinkPipeline` is where URL acceptance and app policy meet.

## Construction

Pass a matcher directly so matcher-specific input limits remain typed
rejections and the pipeline can reuse its parsed URL:

```swift skip doc-fragment
let matcher = DeepLinkMatcher<AppRoute> {
    DeepLinkMapping("/products/:id") { parameters in
        parameters.firstValue(forName: "id").map { .product(id: $0) }
    }
}

let pipeline = DeepLinkPipeline(
    allowedSchemes: ["myapp"],
    allowedHosts: ["app.example.com"],
    matcher: matcher
)
```

For routing rules that need the complete raw URL rather than pattern
matching, use the explicit escape hatch:

```swift skip doc-fragment
let pipeline = DeepLinkPipeline<AppRoute>(
    customResolver: { url in legacyRouter.route(for: url) }
)
```

A custom resolver's `nil` result is `.unhandled`. Pipeline-level input limits
still apply, but only the `matcher:` path can preserve matcher-specific limit
violations.

## Pipeline stages

A pipeline can:

- reject a URL when configured input limits are exceeded
- reject a URL by scheme or host
- leave it unhandled
- resolve it into a route
- require authentication
- convert the route into a `NavigationPlan`

## Pending deep links

When authentication is required but not currently satisfied, the pipeline returns `DeepLinkDecision.pending(_:)`.

This is deliberate:

- the route that triggered authentication deferral is preserved
- the navigation plan is preserved
- replay responsibility remains explicit at the app boundary

That keeps auth transitions and navigation transitions separate instead of blending them into one hidden side effect.

## Planning

The planner converts a route into the exact command list that should run after acceptance. This makes deep-link execution deterministic and testable.

Authentication checks the routes referenced by the produced
`NavigationPlan`, including nested sequences and fallback commands.
If a custom planner returns no route-bearing commands, the pipeline
falls back to the originally resolved route.

Effect handlers and coordinator bridges validate a produced
`NavigationPlan` against the current `RouteStack` before executing it.
Plans that are obviously impossible, such as `.pop` on an empty stack,
surface as typed application rejections instead of partially running.
