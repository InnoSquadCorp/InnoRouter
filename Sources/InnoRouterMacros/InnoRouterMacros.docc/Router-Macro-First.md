# Macro-first routing with `@Router`

@Metadata {
  @PageKind(article)
}

One route declaration unlocks one canonical navigation authority.

## Declare destinations

```swift compile
import SwiftUI
import InnoRouter

@Router
enum LibraryRoute {
    case book(id: String)
    case account

    var destination: some View {
        switch self {
        case .book(let id):
            Text("Book \(id)")
        case .account:
            Text("Account")
        }
    }
}
```

`@Router` synthesizes `DestinationRoute`, including its `Route`,
`Hashable`, and `Sendable` requirements. It also generates the static
destination witness used by native hosts.

## Host one store

```swift skip surrounding-view
RouterHost(LibraryRoute.self) {
    LibraryHomeView()
}
```

Descendants use `@EnvironmentRouter(LibraryRoute.self)`. Named helpers such as
`go`, `back`, `sheet`, and `cover` project into `RouterAction`; use
`perform` when the terminal `RouterOutcome` matters.

## Mix tabs and destinations

```swift skip doc-fragment
@Router
enum AppRoute {
    @TabItem("Library", systemImage: "books.vertical")
    case library

    @TabItem(
        "Account",
        systemImage: "person",
        id: "account",
        selectedSystemImage: "person.fill"
    )
    case account

    case book(id: String)

    var destination: some View { /* exhaustive switch */ }
}
```

Only marked, parameterless cases become tab roots. Unmarked cases remain normal
destinations. By default the macro uses the case name as `RouterScopeID`;
titles and declaration order are not persistence identities. Add a literal
`id:` before renaming a case to keep the persisted tab scope stable. This does
not migrate Codable route cases stored inside that scope's path. Explicit and
default effective IDs must be unique across the enum.

Use `role: .search` only for the route that should adopt SwiftUI's native
search-tab behavior. Role and selected-image metadata do not change the stable
case-name identity.

## Generate typed scenes

Annotate parameterless scene roots with `@Scene`. The router macro generates a
nested `Scene` catalog whose members are either `RouterWindowRequest` or
`RouterImmersiveSpaceRequest`, preventing a request from crossing native scene
styles. Render each instance with `RouterWindowHost` or
`RouterImmersiveSpaceHost` so its stack and presentations remain scene-local
nodes in the one canonical state.

## Generate fail-closed deep links

```swift compile
import SwiftUI
import InnoRouter

@Router(
    deepLinkSchemes: ["myapp", "https"],
    deepLinkHosts: ["app.example.com"]
)
enum LinkedRoute {
    @DeepLink("/books/:id")
    case book(id: String)

    case account

    var destination: some View {
        switch self {
        case .book(let id):
            Text("Book \(id)")
        case .account:
            Text("Account")
        }
    }
}
```

Generated parsing resolves one typed route. `RouterLinkPipeline` promotes that
route into an exact `RouterPlan`, or accepts an app-supplied whole-plan matcher
for tabs, presentations, windows, and immersive state.

Add `inspectorCatalog: true` to `@Router` when development tools need the same
ordered pattern and parameter schema. The generated catalog and
`explainDeepLink(_:)` remain payload-free and do not execute navigation.

## Compile-time diagnostics

The macro rejects invalid declaration shape, conflicting generated members,
malformed patterns, unsupported payloads, invalid tab metadata, and statically
unreachable links. See <doc:Macro-Diagnostics>.
