---
name: innorouter
description: Implement, test, diagnose, or migrate SwiftUI navigation with InnoRouter, including typed routes, hosts, deep links, restoration, and presentation results. Use for projects using or explicitly adopting InnoRouter; unrelated Swift utilities do not need this skill.
---

# InnoRouter

Use the consumer's actual resolved dependency. This skill targets planned stable
**7.0.x** (`>=7.0.0 <7.1.0`), based on unreleased `main` commit
`851c63f095e49b700c3a0aa8152a3521a39977e7`, intended for 7.0.0. **No 7.0.0
release was validated.** The [support record](references/support.json) separates
the intended range from the immutable candidate. Do not silently upgrade a 6.x
consumer, pin it to moving `main`, or claim a future tag is available.

## Choose the relevant guide

- New routes, views, tabs, split or feature composition: [implementation](references/implementation.md).
- URLs, authentication, restoration, persistence and 6→7 migration: [links and restoration](references/links-restoration.md).
- Typed sheets, alerts/dialogs, stale scopes or cancelled results: [presentation and lifetime](references/presentation-lifetime.md).
- Consumer tests, supported patches and release qualification: [testing and compatibility](references/testing-compatibility.md).
- Working examples: [route declaration](assets/consumer/Sources/RouterSkillExample/AppRoute.swift), [SwiftUI setup](assets/consumer/Sources/RouterSkillExample/NavigationViews.swift), and [consumer tests](assets/consumer/Tests/RouterSkillExampleTests/ConsumerTests.swift).

## Core decisions

1. Read `Package.swift`/`Package.resolved` and existing navigation ownership. For
   7.0.x, inspect the actual patch source and manifest. Keep the project's patch
   version; the bundled candidate is reproducible evidence, not a downgrade target.
2. Import the public `InnoRouter` product. Start with `@Router`, its generated
   typed helpers, `RouterHost`/`RouterTabHost`/`RouterSplitHost`, and
   `@EnvironmentRouter`. Read state through `@EnvironmentRouterState`.
3. Let the host own its default store. If application policy/restoration needs
   ownership, create one Store at that boundary and configure its independent
   host declaration before mounting. Scopes and feature hosts project that same
   authority; they do not create another navigation store.
4. In 7.0, edit `RouterStateDraft`, then `try build(resourceBudget:)` and submit
   a `RouterPlan`. `RouterState` is externally read-only. Input-bearing Store
   factories and tab/split hosts throw; handle setup failure explicitly outside
   a nonthrowing SwiftUI `body`. Empty stack conveniences remain nonthrowing.
5. Use `RouterAction` for incremental changes and `RouterPlan` for exact targets.
   Host topology/root meaning changes require the owner's atomic `replaceHost`.
   Policies inspect immutable candidates; business workflow belongs to the app.
6. Treat scope and presentation handles as execution lifetimes. Same logical IDs
   after replacement do not restore old authority. Keep typed value, dismissal,
   cancellation and rejection outcomes distinct.
7. Validate generated code against its exact graph. Use `InnoRouterTesting` for
   host-less event/state/revision assertions. Local consumer success does not
   establish native scene behavior, release readiness, or every supported patch.

Keep migration work within the request. The 5.x `NavigationStore`, `ModalStore`,
`FlowStore`, intent/effect APIs and granular products are not 7.x aliases.
Never insert those from old tutorials into current examples.
