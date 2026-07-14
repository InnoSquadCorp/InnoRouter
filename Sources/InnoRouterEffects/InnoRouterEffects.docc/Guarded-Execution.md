# Guarded execution

@Metadata {
  @PageKind(article)
}

Async policy checks belong at the boundary, not inside the core middleware pipeline.

`NavigationEffectHandler.executeGuarded` supports that rule.

Use it when a command must wait on:

- async authorization
- remote feature flags
- account/session refresh
- capability preflight checks

The helper accepts an async preparation closure that returns `NavigationInterception`:

- `.proceed(updatedCommand)`
- `.cancel(reason)`

That keeps the core deterministic while still giving the app boundary a place to perform async policy work.
