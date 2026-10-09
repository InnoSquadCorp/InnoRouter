# Links, persistence and migration

Declare explicit scheme/host allowlists on `@Router` and route patterns with
`@DeepLink("/products/:id")`. `AppRoute.resolveDeepLink(url)` returns a route or
nil; foreign origins and malformed input must stay rejected. Use generated URL
rendering/resolution and `RouterLinkPipeline` for canonical plan/auth decisions.
Test an accepted URL beside foreign-origin and invalid-input controls. Application
authentication effects belong outside routing policies; pending links retain the
complete plan and must be revalidated after the session changes.

For exact state, copy `RouterStateDraft(existingState)`, change the draft and call
`try draft.build(resourceBudget:)`. Submit `RouterPlan(state:)` through the owning
Store. Valid construction does not authorize execution or bypass its frozen host.
Restore and explicit subtree replacement retire affected scope execution lifetimes,
even when a replacement reuses IDs or has an equal state value.

Choose the persisted contract deliberately: `RouterSnapshotCodec<Route>` supports
Codable routes; `RouterGraphSnapshotCodec` supports stable route keys/versioned
payloads. Both use explicit schema/migration and resource rules. `RouterRestorationDriver`
coordinates app-selected storage and normal policies. Restore errors, typed storage
rejections and transition rejection are separate results. Partial-validation mode
does not use snapshot recovery fallback. Never describe a decoded plan as applied
until the actual transition is accepted.

New tab catalogs require `RouterTabRestorationTopology` before admission. A retired
branch kept with `.preserveDormant` retains state but cannot become a selected
renderer. Ordinary restoration preserves the configured declaration. Intentional
topology/root meaning replacement uses `replaceHost` with a complete matching plan
and descriptor, then a matching renderer. Rejection preserves state and declaration.

Alerts and confirmation dialogs are transient. Snapshot and pending-link codecs
reject them by default before app route encoding. `transientPresentations: .omit`
is an explicit encode-only projection; it leaves live state/results untouched.
Decode, migration admission and restoration must not recreate transient waiters.
Bare Codable is not a persistence workaround. Bounded scenario fixture transport
in `InnoRouterTesting` is separate and cannot import live result authority.

For 6→7 migration, audit: external state writes → drafts; input-bearing setup →
throwing setup; independent host shape and root meanings; finite resource admission;
retired scopes/results; explicit authorization generation/catalog contracts;
transient persistence. For 5.x start from the 6 migration and then 7. Do not migrate
an existing stable consumer solely because this skill knows a newer release.

Native windows and immersive spaces need matching app scene declarations and
stable Store/scene identities. `RouterImmersiveSpaceScene(id:store:)` carries bound
activation identity; an old ID-only callback cannot recover expired authority.
Desktop consumer tests are not native visionOS/iOS lifecycle evidence.

Read the actual patch's guides when implementing advanced behavior. Release baseline:
[7.0 migration](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-7.md),
[tab restoration](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Restoring-Tab-Navigation.md),
[5.x migration](https://github.com/InnoSquadCorp/InnoRouter/blob/33b0da7639105cfa8e6f5acffa3badb91b5e0254/Sources/InnoRouterUmbrella/InnoRouter.docc/Articles/Migrating-To-InnoRouter-6.md).
