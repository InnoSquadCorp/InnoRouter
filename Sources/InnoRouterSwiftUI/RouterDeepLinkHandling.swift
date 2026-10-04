import Foundation
import SwiftUI

import InnoRouterCore
import InnoRouterDeepLink

extension EnvironmentValues {
    @Entry var routerDeepLinkContext: RouterDeepLinkContext?
}

@MainActor
private struct RouterDeepLinkHandlingModifier<R: Route>: ViewModifier {
    @Environment(\.routerDeepLinkContext) private var inheritedContext
    // SwiftUI shares one value for this key inside a Scene and isolates it
    // from other Scene instances. Nested hosts inherit the same arbiter
    // directly; sibling roots meet again through the scene registry.
    @SceneStorage("io.innosquad.innorouter.macro-first-deep-link-scene")
    private var sceneIdentifier = UUID().uuidString
    @State private var source = RouterDeepLinkSource()

    let routeType: R.Type
    let action: @MainActor @Sendable (R) -> Void

    func body(content: Content) -> some View {
        let context = RouterDeepLinkContext(
            arbiter: inheritedContext?.arbiter ??
                RouterDeepLinkSceneArbiterRegistry.arbiter(for: sceneIdentifier),
            depth: inheritedContext.map { $0.depth + 1 } ?? 0
        )
        content
            .environment(\.routerDeepLinkContext, context)
            .onOpenURL { url in
                submitRouterDeepLink(
                    routeType,
                    url: url,
                    context: context,
                    source: source,
                    action: action
                )
            }
    }
}

extension View {
    @MainActor
    func handleRouterDeepLinks<R: Route>(
        for routeType: R.Type,
        action: @escaping @MainActor @Sendable (R) -> Void
    ) -> some View {
        modifier(
            RouterDeepLinkHandlingModifier(
                routeType: routeType,
                action: action
            )
        )
    }
}

@MainActor
private struct RouterPlanLinkHandlingModifier<R: Route>: ViewModifier {
    @Environment(\.routerDeepLinkContext) private var inheritedContext
    @SceneStorage("io.innosquad.innorouter.plan-deep-link-scene")
    private var sceneIdentifier = UUID().uuidString
    @State private var source = RouterDeepLinkSource()

    let routeType: R.Type
    let scope: RouterScope<R>
    let handling: RouterLinkHandling<R>?
    let fallbackPlan: @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R>

    func body(content: Content) -> some View {
        let context = RouterDeepLinkContext(
            arbiter: inheritedContext?.arbiter ??
                RouterDeepLinkSceneArbiterRegistry.arbiter(for: sceneIdentifier),
            depth: inheritedContext.map { $0.depth + 1 } ?? 0
        )
        content
            .environment(\.routerDeepLinkContext, context)
            .onOpenURL { url in
                submit(url, context: context)
            }
    }

    private func submit(_ url: URL, context: RouterDeepLinkContext) {
        submitRouterPlanLink(
            routeType, url: url, scope: scope, context: context,
            source: source, handling: handling, fallbackPlan: fallbackPlan
        )
    }
}

extension View {
    /// Applies accepted deep links as complete plans through one router store.
    @MainActor
    func handleRouterPlans<R: Route>(
        for routeType: R.Type,
        scope: RouterScope<R>,
        handling: RouterLinkHandling<R>?,
        fallbackPlan: @escaping @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R>
    ) -> some View {
        modifier(
            RouterPlanLinkHandlingModifier(
                routeType: routeType,
                scope: scope,
                handling: handling,
                fallbackPlan: fallbackPlan
            )
        )
    }
}
