// MARK: - RouterDeepLinkHandling.swift
// InnoRouterSwiftUI - macro-first incoming URL arbitration
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import OSLog
import SwiftUI

import InnoRouterCore
import InnoRouterDeepLink

@MainActor
final class RouterDeepLinkSource: Sendable {}

@MainActor
final class RouterDeepLinkArbiter: Sendable {
    private struct Candidate {
        let source: RouterDeepLinkSource
        let depth: Int
        let action: @MainActor @Sendable () -> Void
    }

    private static let logger = Logger(
        subsystem: "io.innosquad.innorouter",
        category: "macro-first-deep-link"
    )

    private var pending: [URL: Candidate] = [:]
    private var scheduledURLs: Set<URL> = []
    private var ambiguousURLs: Set<URL> = []

    func submit(
        url: URL,
        source: RouterDeepLinkSource,
        depth: Int,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        if let current = pending[url] {
            if current.source === source {
                return
            }
            if depth < current.depth {
                pending[url] = Candidate(
                    source: source,
                    depth: depth,
                    action: action
                )
            } else if depth == current.depth, ambiguousURLs.insert(url).inserted {
                Self.logger.warning(
                    "Multiple macro-first hosts resolved one incoming URL at the same nesting depth; the first candidate will handle it."
                )
            }
        } else {
            pending[url] = Candidate(
                source: source,
                depth: depth,
                action: action
            )
        }

        guard scheduledURLs.insert(url).inserted else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.flush(url)
        }
    }

    func flush(_ url: URL) {
        scheduledURLs.remove(url)
        ambiguousURLs.remove(url)
        pending.removeValue(forKey: url)?.action()
    }
}

@MainActor
private final class RouterDeepLinkWeakArbiter: Sendable {
    weak var value: RouterDeepLinkArbiter?

    init(_ value: RouterDeepLinkArbiter) {
        self.value = value
    }
}

@MainActor
enum RouterDeepLinkSceneArbiterRegistry {
    private static var arbiters: [String: RouterDeepLinkWeakArbiter] = [:]

    static func arbiter(for sceneIdentifier: String) -> RouterDeepLinkArbiter {
        arbiters = arbiters.filter { $0.value.value != nil }
        if let arbiter = arbiters[sceneIdentifier]?.value {
            return arbiter
        }
        let arbiter = RouterDeepLinkArbiter()
        arbiters[sceneIdentifier] = RouterDeepLinkWeakArbiter(arbiter)
        return arbiter
    }
}

struct RouterDeepLinkContext: Sendable {
    let arbiter: RouterDeepLinkArbiter
    let depth: Int
}

extension EnvironmentValues {
    @Entry var routerDeepLinkContext: RouterDeepLinkContext?
}

@MainActor
@discardableResult
func submitRouterDeepLink<R: Route>(
    _ routeType: R.Type,
    url: URL,
    context: RouterDeepLinkContext,
    source: RouterDeepLinkSource,
    action: @escaping @MainActor @Sendable (R) -> Void
) -> Bool {
    guard let resolver = routeType as? any DeepLinkRoute.Type,
          let route = resolver.resolveDeepLink(url) as? R else {
        return false
    }
    context.arbiter.submit(
        url: url,
        source: source,
        depth: context.depth
    ) {
        action(route)
    }
    return true
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
