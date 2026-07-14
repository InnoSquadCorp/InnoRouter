# Boundary execution

@Metadata {
  @PageKind(article)
}

`NavigationEffectHandler` wraps a batch- and transaction-capable navigator boundary.

Use it when command execution belongs to:

- app shells
- coordinators
- effect layers
- feature orchestration code

The handler mirrors the core semantics explicitly:

- single-command execution
- batch execution
- transaction execution

It also exposes `events: AsyncStream<NavigationEffectHandlerEvent<R>>`
so boundary code can observe single, batch, and transaction outcomes
without polling mutable "last result" properties.
