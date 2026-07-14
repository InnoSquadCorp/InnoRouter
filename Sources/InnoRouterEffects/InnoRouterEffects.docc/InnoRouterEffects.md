# InnoRouterEffects

Use `InnoRouterEffects` at app and feature boundaries that execute navigation
commands or turn deep-link decisions into typed execution outcomes.

The 5.0 module owns the complete effects surface directly:

- `NavigationEffectHandler` executes commands, batches, transactions, and
  guarded async preparation.
- `DeepLinkEffectHandler` applies push-only deep-link plans and retains one
  pending link for authenticated replay.
- `FlowDeepLinkEffectHandler` applies composite `FlowPlan` values atomically.
- `NavigationEffect` and `DeepLinkEffect` adapt feature effects without making
  the core runtime depend on a reducer framework.

```swift compile
import InnoRouterEffects

enum EffectsRoute: Route {
    case home
}

let command: NavigationCommand<EffectsRoute> = .push(.home)
_ = command
```

## Topics

### Navigation execution

- <doc:Boundary-Execution>
- <doc:Guarded-Execution>

### Deep-link execution

- <doc:Deep-Link-Effect-Handling>
