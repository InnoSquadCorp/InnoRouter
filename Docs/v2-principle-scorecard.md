# InnoRouter Principle Scorecard

This scorecard maps the current implementation to SwiftUI philosophy, SOLID, typed execution semantics, and the repository’s release/documentation discipline.

## Architecture mapping

| Axis | Current state | Evidence | Status |
|---|---|---|---|
| Core semantics | Typed route stack, command algebra, batch, and transaction execution | `Sources/InnoRouterCore` | Enforced |
| SwiftUI authority | Stack, split-detail, and modal surfaces are separated by host/store responsibility | `Sources/InnoRouterSwiftUI` | Enforced |
| Spatial authority | visionOS windows, volumes, immersive spaces, and ornaments live in an explicit opt-in product outside the default umbrella | `Sources/InnoRouterSpatial` | Enforced |
| Deep-link planning | URL matching and policy flow are explicit, typed, and replay-friendly | `Sources/InnoRouterDeepLink` | Enforced |
| App boundary effects | Navigation and deep-link execution share one opt-in app-boundary module | `Sources/InnoRouterEffects` | Enforced |
| Host-less testability | `NavigationTestStore`, `ModalTestStore`, and `FlowTestStore` expose a shippable Swift Testing harness over the public observation surface | `Sources/InnoRouterTesting` | Enforced |
| Coordinator composition | `ChildCoordinator` + `parent.push(child:) -> Task<Result?, Never>` give child → parent finish chaining with inline `await`, symmetric with SwiftUI authority boundaries | `Sources/InnoRouterSwiftUI/ChildCoordinator.swift`, `Docs/design-child-coordinator-handoff.md` | Enforced |
| Unified observation stream | Navigation, Modal, and Flow stores publish a typed configuration `onEvent` callback; every authority, including `SceneStore`, publishes a matching `events: AsyncStream<Event>`. `FlowStore` wraps inner navigation / modal emissions so either channel sees the complete chain. | `Sources/InnoRouterCore/EventBroadcaster.swift`, `Sources/InnoRouterSwiftUI/{NavigationEvent,ModalEvent,FlowEvent}.swift`, `Sources/InnoRouterSpatial/SceneStore.swift` | Enforced |
| Codable state restoration | Opt-in `Codable` on `RouteStack`, `RouteStep`, and `FlowPlan` with a typed `StatePersistence<R>` Data-boundary helper. No file I/O policy is baked in — apps own the transport. | `Sources/InnoRouterCore/StatePersistence.swift`, Codable extensions on value types | Enforced |
| Tutorial-grade DocC | Narrative articles sit beside the symbol reference, covering onboarding flows, deep-link reconciliation, middleware composition, host migration, spatial scenes, composite URL rehydration, and host-less testing | `Sources/InnoRouterSwiftUI/InnoRouterSwiftUI.docc/Articles/`, `Sources/InnoRouterSpatial/InnoRouterSpatial.docc/Articles/`, `Sources/InnoRouterDeepLink/InnoRouterDeepLink.docc/Articles/`, `Sources/InnoRouterTesting/InnoRouterTesting.docc/Articles/` | Enforced |
| Composite deep-link rehydration | A single URL maps to a `FlowPlan<R>` carrying both a push prefix and an optional modal terminal step. `FlowDeepLinkEffectHandler` drives the plan through `FlowStore.apply` atomically, with the same authentication-deferral loop as the push-only pipeline. | `Sources/InnoRouterDeepLink/{DeepLink,FlowDeepLinkPipeline}.swift`, `Sources/InnoRouterEffects/FlowDeepLinkEffectHandler.swift` | Enforced |
| Command algebra + rate-limiting | `.whenCancelled(primary, fallback:)` is a synchronous fallback primitive with a savepoint per leg, so only one successful leg commits; `ThrottleNavigationMiddleware` is a Clock-generic middleware that cancels commands within a minimum interval of a previously accepted key. Both compose through the existing middleware + engine pipeline. | `Sources/InnoRouterCore/NavigationCommand.swift`, `Sources/InnoRouterSwiftUI/ThrottleNavigationMiddleware.swift` | Enforced |
| Cross-launch pending deep links | `FlowPendingDeepLink` is opt-in `Codable` when the route is `Codable`. `FlowPendingDeepLinkPersistence<R>` bridges to `Data`, and `FlowDeepLinkEffectHandler.restore(pending:)` re-installs a decoded pending link for replay through the authentication policy. | `Sources/InnoRouterDeepLink/FlowPendingDeepLinkPersistence.swift` | Enforced |
| Macro diagnostics + FixIts | `@Routable` and `@CasePathable` share a `MacroDiagnostic` layer. Misapplication on `struct` / `class` offers a Swift FixIt to change the declaration keyword to `enum`. Empty enums surface an error instead of silently expanding to nothing. | `Sources/InnoRouterMacrosPlugin/MacroDiagnostic.swift` | Enforced |
| Documentation | README and DocC coexist; module-level docs live beside sources | `README.md`, `Sources/*/*.docc` | Enforced |
| Release discipline | Semver tags, DocC publishing, and GitHub Releases share one flow | `.github/workflows/release.yml`, `RELEASING.md` | Enforced |

## SwiftUI philosophy

Positive alignment:

- Views emit `NavigationIntent` and `ModalIntent` instead of mutating stores directly.
- Stack routing, modal routing, and split-detail routing are different authorities rather than one overloaded state bucket.
- Environment wiring is fail-fast.
- `NavigationStore` and `ModalStore` expose explicit authority boundaries rather than hiding side effects in views.

Intentional trade-offs:

- `NavigationStore`, `ModalStore`, and `Coordinator` remain reference types because they represent shared authority, not ephemeral local state.
- Column visibility and sidebar selection remain app-owned instead of being absorbed into router state.

## Execution model

InnoRouter deliberately exposes three semantics instead of collapsing them:

- `.sequence`: left-to-right command algebra
- `executeBatch`: observation batching
- `executeTransaction`: atomic all-or-nothing commit

This separation improves reasoning and testing because each semantic has one clear contract.

## Documentation and release quality

The repository now treats documentation as a first-class artifact:

- `.md` files explain repository-level usage and release process
- `.docc` catalogs cover module-level concepts and symbols
- CI validates DocC generation on every PR
- CD publishes versioned docs and a `latest` alias from the same semver tag that cuts the library release

## Current strengths

- Typed failures stay in normal control flow.
- Middleware cancellation reasons are explicit.
- Deep-link matcher diagnostics catch ambiguity without changing precedence.
- Modal routing exposes the same middleware surface as navigation (`ModalMiddleware`, `AnyModalMiddleware`, CRUD API, and `.middlewareMutation` / `.commandIntercepted` events through `onEvent`), so gating and analytics hooks compose symmetrically across both authorities.
- `FlowStore<R>` represents push + sheet + cover progression as a single `[RouteStep<R>]` value, delegating execution to the existing `NavigationStore` + `ModalStore` without removing their individual authorities.
- `InnoRouterTesting` ships `NavigationTestStore` / `ModalTestStore` / `FlowTestStore` as a shippable Swift-Testing-native harness with TCA-style strict exhaustivity, so consumers no longer need `@testable import` to assert routing behaviour.
- `NavigationStoreConfiguration.onEvent` surfaces `.pathMismatch` alongside every other navigation observation case, completing the public observation surface with one callback.
- Child coordinators chain to parents through `ChildCoordinator` + `Coordinator.push(child:) -> Task<Result?, Never>`, so parent flows can `await` child finish values inline without hand-rolled continuation plumbing. Parent Task cancellation propagates to the child through `ChildCoordinator.parentDidCancel()` (default no-op), so transient child state tears down cleanly when the parent view is dismissed.
- Case-typed destination bindings (`NavigationStore.binding(case:)`, `ModalStore.binding(case:style:)`) route every SwiftUI set through the existing command pipeline so middleware and telemetry observe them identically to direct `execute(...)`.
- High-frequency navigation intents (`replaceStack`, `backOrPush`, `pushUniqueRoot`) compose from existing `NavigationCommand` primitives so the engine stays minimal while app code stays declarative.
- Human-facing examples and smoke fixtures are intentionally separated.
- `InnoRouterSpatial` keeps multi-scene authority out of the default umbrella;
  consumers pay for and import the surface only in targets that own spatial
  scene declarations.

## Remaining trade-offs

- SwiftUI shell state such as split column visibility is still app-owned.
- Alerts and confirmation dialogs remain outside the framework scope.
- Core middleware stays synchronous by design; async policy belongs at effect boundaries.

These are intentional scope boundaries, not accidental omissions.

## Spatial module boundary

The 5.0 API promotes spatial routing from its 4.x experimental location in
`InnoRouterSwiftUI` to the stable, opt-in `InnoRouterSpatial` product.
The default `InnoRouter` umbrella intentionally does not re-export it.
Scene declarations and ornaments remain available cross-platform where their
types are meaningful; `SceneStore` and the scene host/anchor modifiers are
declared only on visionOS.
