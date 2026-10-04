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

## Distinguish direct dismissal from removed ownership

A directly dismissed presentation finishes its awaiting result as `.dismissed`.
A successful typed completion returns `.value` only to that presentation's
waiter. Removing its parent cancels descendant waiters; it does not report that
each descendant was independently dismissed. Exact restoration and explicit
replacement also cancel the retired waiter, including replacement that reuses
the logical presentation UUID.

A rejected or deferred dismissal keeps the active state and waiters until an
accepted transition removes them. A child result that committed before parent
removal remains its completed value; a parent removed first cancels that child
and cannot deliver a late child result.

## Keep transient presentations out of restoration

A stack has one `presentationFamily`: navigation, alert, or confirmation dialog.
The existing `presentation` property remains a navigation-only compatibility
view. Assigning `nil` to that view does not clear an alert or dialog; use the
canonical dismissal action.

Transient display descriptors contain no route, child navigation node, task,
callback, or typed result. An alert ID therefore cannot address a child scope.
The pure reducer validates button IDs and removes exactly the selected family.

Snapshot and pending-link codecs reject transient families before invoking app
route encoders by default. Choose `transientPresentations: .omit` explicitly to
save navigation while dropping transient leaves from the encoded copy. The
original complete state still has to fit its configured resource budget. Live
state and awaiting callers are unaffected by that encoding projection.

Omission is encode-only. Decoding, migration admission, fallback, and partial
restoration reject transient UI rather than recreating an action or result
waiter. Bare Codable export of transient state or present actions also fails;
it is not a supported persistence workaround.

Typed legacy migration conveniences screen the known `RouterState` and
`RouterPlan` input shapes before app route decoding. Arbitrary app-owned input
and output wrappers remain the application's schema responsibility. Explicit
`limits: nil` retains historical raw migration formats; it does not claim
bounded parsing, and the final transformed state must still decode and validate.
