# Routable and CasePathable

@Metadata {
  @PageKind(article)
}

Use case-path macros when route code needs typed enum extraction in addition to
InnoRouter's macro-first destination routing.

For most SwiftUI routers, start with `@Router`. It combines route data and
destination views in one enum. Add one of the case-path macros only when a
feature also needs to inspect or extract a particular enum case.

## `@Routable`

`@Routable` generates `Route` conformance plus typed `Cases`, `is(_:)`,
and `subscript(case:)` helpers. It is useful for route models that do not own
destination views, such as a domain route consumed by a coordinator or planner.

Do not repeat `: Route`; the macro supplies that conformance:

```swift compile
import InnoRouter

@Routable
enum AccountRoute {
    case overview
    case profile(userID: String)
}

let route = AccountRoute.profile(userID: "42")
route[case: AccountRoute.Cases.profile]  // Optional("42")
route.is(AccountRoute.Cases.overview)    // false
```

## `@CasePathable`

`@CasePathable` generates the same case-path members without adding
`Route` conformance. Compose it with `@Router` when a destination-owning
router also needs typed extraction:

```swift compile
import SwiftUI
import InnoRouter

@Router
@CasePathable
enum SearchRoute {
    case result(id: String)

    var destination: some View {
        Text("Search result")
    }
}

let route = SearchRoute.result(id: "42")
route[case: SearchRoute.Cases.result]  // Optional("42")
```

It is also useful on enums that are not routes at all but still need reusable
case extraction.

## Examples vs smoke fixtures

The repository intentionally builds both example layers:

- `Examples/` exercises the current idiomatic, macro-driven API and every
  human-facing example has a SwiftPM build target.
- `ExamplesSmoke/` mirrors the public runtime surface with conservative
  fixtures. Its dedicated `MacrosSmoke.swift` target depends only on
  `InnoRouter` and proves the one-product macro-first consumer contract.

Macro expansion itself is covered by `InnoRouterMacrosTests` and
`InnoRouterMacrosBehaviorTests`.

## Limitations: generic enums

Both `@Routable` and `@CasePathable` reject generic enum declarations with an
explicit compiler error:

```swift skip doc-fragment
@Routable
enum Generic<T> { case detail(T) } // error: @Routable does not support generic enum declarations
```

The generated `enum Cases` would need to materialise `CasePath<Self, T>`
members for each generic instantiation, but Swift does not propagate the
parent's generic parameters into a nested type that way. Diagnostic ID
`InnoRouterMacros.unsupportedGenericEnum` is emitted on the generic parameter
clause.

This limitation does not apply to `@Router`. A constrained generic router is
supported as long as its payloads satisfy the `Route` requirements:

```swift compile
import SwiftUI
import InnoRouter

@Router
enum DetailRoute<Value: Hashable & Sendable> {
    case detail(Value)

    var destination: some View {
        Text("Detail")
    }
}
```

If a case-path route needs a generic data shape, expose a concrete payload type
from the non-generic route enum:

```swift skip doc-fragment
struct DetailPayload<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value
}

typealias StringDetailPayload = DetailPayload<String>

@Routable
enum AppRoute {
    case home
    case detail(StringDetailPayload)
}
```
