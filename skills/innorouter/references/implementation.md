# Routes and host ownership

`@Router` generates the `DestinationRoute`/route support and typed helpers. A route
enum provides `var destination: some View` with an exhaustive switch. Add `Codable`
when using the Codable snapshot adapter; route identity and stable serialization
are application contracts. Import `InnoRouter`, not internal target modules.

Use `RouterHost(AppRoute.self) { HomeView() }` for an empty stack. A child view's
`@EnvironmentRouter(AppRoute.self)` exposes focused actions such as `go`, `back`,
`sheet`, `cover`, `dismiss`; `@EnvironmentRouterState` reads path, tab state and
`presentationFamily`. Navigation-only `presentation` does not reveal alerts/dialogs.

The empty `AppRoute.makeRouterStore()`/`RouterStore<AppRoute>()` is nonthrowing and
stack-shaped, even if the enum has tabs. A caller-owned store rendered by a native
host needs a matching descriptor. For the default stack root:

```swift
let store = try AppRoute.makeRouterStore(configuration: .init(hostDescriptor: .init(
    root: .stack,
    rootDeclarations: [.init(meaning: .declarationID("router.root"))]
)))
```

`RouterHost(store:)` stays nonthrowing; missing/mismatched declarations appear as
`validationFailure` and recovery UI. It does not silently register the host.

Mark parameterless tab roots with `@TabItem`. Explicit `id:` preserves scope
identity across case renames; Codable route payload migration is still separate.
`try RouterTabHost(AppRoute.self, initial: .home)` constructs the complete topology.
Prepare a `Result<RouterTabHost<AppRoute>, Error>` in setup and render success or
an error view. Do not use `try!`, discard errors with `try?`, or wrap every route
in another Store. See the [compiled setup](../assets/consumer/Sources/RouterSkillExample/NavigationViews.swift).

For app-owned tabs use `RouterTabCatalog` and `catalog.hostDescriptor()`; a shape
alone does not freeze root Route meanings. Split setup uses `RouterSplitHost` or
`RouterThreeColumnSplitHost`, the matching layout and stable closure declaration
IDs. Configure `layout.hostShape` plus `layout.hostRootDeclarations(for:...)`.
The same IDs must reach the renderer. A changed root meaning requires
`replaceHost(with:descriptor:context:)`; ordinary apply/restore does not reconfigure it.

`@FeatureRoute("account.primary") case account(AccountRoute)` plus
`RouterFeatureHost(AppRoute.Feature.account)` composes an independent feature's
route into the parent. It forwards through the same policies, queue and revision.
Its projection must own its complete subtree. Scene opening remains app-owned.

Use finite `RouterResourceBudget` settings selected for the workload. Invalid
negative settings throw, zero admits no matching work, and `.unlimited` is an
explicit opt-out. Validation does not truncate input or raise a budget for it.

Exact candidate sources: [README](https://github.com/InnoSquadCorp/InnoRouter/blob/851c63f095e49b700c3a0aa8152a3521a39977e7/README.md),
[macro-first examples](https://github.com/InnoSquadCorp/InnoRouter/blob/851c63f095e49b700c3a0aa8152a3521a39977e7/Examples/MacrosExample.swift),
[7.0 migration](https://github.com/InnoSquadCorp/InnoRouter/blob/851c63f095e49b700c3a0aa8152a3521a39977e7/Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md).
