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
    try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}

@MainActor
func makePopulatedStore() throws -> RouterStore<AppRoute> {
    try RouterStore(initialPath: [AppRoute.settings], configuration: .init(hostDescriptor: .init(
        root: .stack,
        rootDeclarations: [.init(meaning: .declarationID("router.root"))]
    )))
}
```

Catch initialization errors in application setup and show the appropriate error
or recovery UI. Supplied-store tab and split hosts now also throw. Configure the
Store's `hostDescriptor` before injecting it into any native host. The existing
`RouterHost(store:)` and platform bridge factories remain nonthrowing; the stack
host exposes `validationFailure` and renders recovery UI for a missing or
incompatible declaration. Host construction validates the existing declaration;
it never registers or changes it. Do not hide failure
with `try!`, `try?`, or an unrelated fallback state.

`RouterHost(Route.self) { ... }` keeps its nonthrowing empty convenience.
Supplying paths or configuration uses a throwing overload. Tab and split host
constructors accepting selection, catalog, layout, paths, or configuration also
throw. Create them before entering a nonthrowing SwiftUI `body`, or retain a
setup result and render either its host or an explicit error view.

## Declare the renderer before mounting it

A native renderer freezes both its shape and its root meanings. A configured
stack uses `RouterHostDescriptor(root: .stack, rootDeclarations:
[.init(meaning: .declarationID("router.root"))])` for the default stack host and
platform bridge factories. Their additive `rootDeclarationID` parameter lets
an application choose another stable semantic ID without changing the existing
nonthrowing signatures.

A tab renderer uses `catalog.hostDescriptor(orphanPolicy:)`, which freezes
each scope ID's root Route value. `catalog.hostShape(orphanPolicy:)` alone is
insufficient for native tab rendering. A catalog with the same IDs, ordering,
and node kinds but different root routes is rejected as `.rendererMismatch`.

A split renderer combines `layout.hostShape` with
`layout.hostRootDeclarations(for:sidebarDeclarationID:detailDeclarationID:)`
(or the three-column overload including `contentDeclarationID`). Pass the same
layout and semantic declaration IDs to the supplied-store host. Arbitrary
column closures require these IDs explicitly; change an ID when the root's
meaning changes. For typed route roots, compose recursive split branches with
`RouterHostViewDescriptor.route(_:)`, which freezes the actual Route values.

`RouterHostViewDescriptor.stack(declarationID:)` also requires a stable ID for
its root closure. Recursive tab/split/custom descriptors prefix the child root
mappings automatically. Configure their Store with both `rendering.shape` and
`rendering.rootDeclarations`; child scopes validate their relative subtree.
Labels, localization, icons, and styling are presentation metadata, not root
meaning. Opaque closure semantics are an application declaration: the library
compares the supplied IDs and does not inspect a closure's implementation.

The configured initial state and renderer must match the complete declaration,
including ordered tabs, child node kinds, split role IDs, root meanings, and
orphan policy.

Replace `allowingOrphanedBranches: true` with `orphanPolicy: .preserveDormant`
in both the catalog descriptor and the host. Preserved branches retain their
state and remain structurally validated; they cannot be selected or rendered.
Use `RouterTabRestorationTopology` explicitly before admission to add current
tabs and move selection away from retired branches. A missing or incompatible
shape produces `RouterHostValidationFailure`, never an empty fallback scope.

Ordinary actions, links, transactions, and restoration retain the declared host
contract. To intentionally change topology or root meaning, call the owning Store's
`replaceHost(with:descriptor:context:)` with the complete state plan and the new
independent declaration, then construct its matching renderer. This uses the
normal policy pipeline and commits state and declaration atomically. Rejected
replacement preserves both; accepted replacement retires old scope authority,
including when node IDs are reused. Child scopes cannot replace the contract.

The descriptor's presentation, window, and immersive catalogs are frozen
route-to-declaration mappings. The default presentation child is a stack;
window and immersive catalogs default to none. Declare other nested hosts
explicitly. A route resolver selects a predeclared identifier; it must not
construct a shape from the incoming candidate or mutate captured configuration.

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

## Await a typed transient response

`RouterTransientPresentationRequest<Value>` declares display metadata and the
value associated with each button. `Value` only needs `Sendable`; it is not
serialized, hashed, or invoked by the router. A cancel-role button returns its
declared value. Dismissing without a selected button returns `.dismissed`, while
caller cancellation or owner replacement returns `.cancelled`.

```swift
let confirmation = RouterTransientPresentationRequest<Bool>.confirmationDialog(
    title: "Remove item?",
    actions: [
        .init(id: "remove", label: "Remove", role: .destructive, value: true),
        .init(id: "keep", label: "Keep", role: .cancel, value: false),
    ]
)
let result = await store.present(confirmation)
```

Reusing a declaration creates a fresh presentation ID and independent waiter.
Each scope still has one exclusive presentation family. Result delivery retains
the original scope, feature projection, and configured authorization generation
through queueing, policy suspension, and deferral. An application without a
generation provider cannot ask the router to infer account/session changes.

A renderer captures `presentationHandle()` and forwards a selected button with
`selectPresentationAction(_:using:)`. The handle expires on ownership replacement,
even when the logical ID and state value are unchanged. `dismissPresentation(using:)`
uses the same captured authority. Raw selection actions still pass through the
same result ownership and policy checks. Public transition-context metadata does
not grant authority to complete a deferred result.

Scenario fixtures use a separate bounded descriptor transport:
`RouterScenarioFixture.encode(resourceBudget:outputFormatting:)` and the bounded
fixture decoding APIs. Format 9 transports display descriptors and declared
button IDs, not live waiters or values. Navigation-only format 8 inputs remain
supported. A replay limitation identifies operations that require live result
authority; importing descriptors does not recreate it. Snapshot, pending-link,
and restoration codecs remain isolated from this Testing-only transport.
