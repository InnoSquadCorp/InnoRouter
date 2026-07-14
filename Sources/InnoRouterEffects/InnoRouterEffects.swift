// MARK: - InnoRouterEffects.swift
// InnoRouterEffects - App-boundary Effect Integration
// Copyright © 2025 Inno Squad. All rights reserved.

@_exported import InnoRouterCore
@_exported import InnoRouterDeepLink

// MARK: - Module Overview
//
// InnoRouterEffects owns the complete app-boundary effect surface.
//
// ## Key Types
// - `NavigationEffectHandler`: Execute NavigationCommand as Effects
// - `DeepLinkEffectHandler`: Handle deep links as Effects
// - `AnyBatchNavigator`: Type erasure for batch-aware navigation boundaries
// - `NavigationEffect`: Protocol for Effects containing NavigationCommand
// - `DeepLinkEffect`: Protocol for Effects containing deep links
//
// ## Usage with InnoFlow (example)
//
// ```swift
// @InnoFlow
// struct ProductFeature {
//     struct State: Equatable, Sendable {
//         var selectedProductID: String?
//     }
//
//     enum Action: Equatable, Sendable {
//         case productTapped(String)
//         case backTapped
//         case _navigationRequested(NavigationCommand<ProductRoute>)
//     }
//
//     var body: some Reducer<State, Action> {
//         Reduce { state, action in
//             switch action {
//             case .productTapped(let id):
//                 state.selectedProductID = id
//                 return .send(._navigationRequested(.push(.detail(id: id))))
//             case .backTapped:
//                 return .send(._navigationRequested(.pop))
//             case ._navigationRequested:
//                 return .none
//             }
//         }
//     }
// }
//
// @MainActor
// func bindNavigation(
//     store: Store<ProductFeature>,
//     handler: NavigationEffectHandler<ProductRoute>
// ) {
//     // Keep route ownership in InnoRouter. The feature only emits navigation intent.
//     if case let .some(id) = store.selectedProductID {
//         handler.execute(.push(.detail(id: id)))
//     }
// }
// ```
//
// Batch semantics:
// - `execute(.sequence(...))` remains command algebra and observes each step individually.
// - `execute([command, ...])` uses `executeBatch` semantics and returns `NavigationBatchResult`.
//
// ## Comparison: Standalone vs Effect-driven
//
// | Feature | InnoRouter (Standalone) | InnoRouterEffects |
// |---------|-------------------------|-------------------|
// | Import | `import InnoRouter` | `import InnoRouterEffects` |
// | Navigation | `router.push()` | `store.send(._navigationRequested(.push()))` |
// | State | Direct Router | InnoFlow business state + app/coordinator boundary binding |
// | DeepLink | DeepLinkHandler | DeepLinkEffectHandler |
// | Testability | Manual | InnoFlow TestStore |
