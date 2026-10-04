# Migrating initialization to InnoRouter 7

Handle external initial state and resource configuration at a throwing setup boundary.

## Keep the empty convenience

`RouterStore<Route>()` and `Route.makeRouterStore()` remain nonthrowing. Both
create a known-valid empty root stack with finite provisional defaults.
`@Router` supplies the `DestinationRoute` conformance that makes the factory
available; its actual API name is `makeRouterStore`.

## Handle input failures

Passing `initialState`, `initialPath`, or `configuration` requires `try`.
Initialization validates resource limits before recursively checking structure
and scene-catalog membership. Invalid input produces a typed error without
trapping, truncating state, choosing another root, or increasing its budget.

```swift compile
import SwiftUI
import InnoRouter

@Router
enum AppRoute {
    case settings
    var destination: some View { Text("Settings") }
}

@MainActor
func makeConfiguredStore() throws -> RouterStore<AppRoute> {
    try AppRoute.makeRouterStore(configuration: .init())
}

@MainActor
func makePopulatedStore() throws -> RouterStore<AppRoute> {
    try RouterStore(initialPath: [AppRoute.settings])
}
```

Catch initialization errors in application setup and show the appropriate error
or recovery UI. Inject a successfully created Store into `RouterHost(store:)`,
`RouterTabHost(store:)`, or a split host. Do not hide failure with `try!`, `try?`,
or an unrelated fallback state.

`RouterHost(Route.self) { ... }` keeps its nonthrowing empty convenience.
Supplying paths or configuration uses a throwing overload. Tab and split host
constructors accepting selection, catalog, layout, paths, or configuration also
throw. Create them before entering a nonthrowing SwiftUI `body`, or retain a
setup result and render either its host or an explicit error view.

## Select resource settings deliberately

`RouterStoreConfiguration(resourceBudget:)` applies one explicit
`RouterResourceBudget`. Queue, deferral, and active-operation settings remain
available as synchronized compatibility properties. Replacing a budget keeps
the configured overflow strategies.

Finite development defaults include 256 queued requests, 64 deferrals, 64
active policy/authorization operations, eight active restoration operations,
a 30-second policy timeout, and a 15-minute deferral lifetime. Explicit `nil`
deadlines and active-operation counts still opt out. Zero capacity and negative
configuration values are distinct: zero admits no corresponding work, while
negative counts or deadlines throw a configuration failure.

Use measured larger finite values when needed. `RouterResourceBudget.unlimited`
is an explicit opt-out from finite-resource guarantees. It is never selected
implicitly to accommodate a large initial state or static tab declaration.
A tab host whose complete generated topology exceeds its budget throws rather
than dropping tabs or changing root topology. Empty `makeRouterStore()` retains
its root-stack semantics; it does not infer a tab or split root.

Store transactions, feature preparation, subtree replacement, and default host
link planners pass the owner's selected budget through plan construction.
Standalone plan builders and reducers use provisional finite defaults and
provide explicit budget overloads. Resource rejection does not run policies,
assign state, or increment revision.
