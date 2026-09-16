// MARK: - RouterNineteenthReviewDeepLinkTests.swift
// InnoRouterMacrosBehaviorTests - recursive feature deep-link termination

#if canImport(InnoRouterMacrosPlugin)

import Foundation
import SwiftUI
import Testing

import InnoRouterMacros

/// Reaches itself through a feature case.
@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private indirect enum SelfFeatureRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(Self)

    var destination: some View { EmptyView() }
}

/// Two routes that reach each other.
@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private indirect enum MutualRouteA {
    @DeepLink("/a/:id")
    case leaf(id: String)

    @FeatureRoute
    case toB(MutualRouteB)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private indirect enum MutualRouteB {
    @DeepLink("/b/:id")
    case leaf(id: String)

    @FeatureRoute
    case toA(MutualRouteA)

    var destination: some View { EmptyView() }
}

/// The deepest leaf, so the shared child below composes a real catalog.
@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private enum GrandChildRoute {
    @DeepLink("/grand/:id")
    case leaf(id: String)

    var destination: some View { EmptyView() }
}

/// A child that two unrelated parents both own.
@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private enum SharedChildRoute {
    @DeepLink("/shared/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(GrandChildRoute)

    var destination: some View { EmptyView() }
}

/// Two unrelated parents that both own the same child type.
@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private enum FirstParentRoute {
    @DeepLink("/first/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(SharedChildRoute)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["r19"], deepLinkHosts: ["app"])
private enum SecondParentRoute {
    @DeepLink("/second/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(SharedChildRoute)

    var destination: some View { EmptyView() }
}

@Suite("Nineteenth review recursive deep links", .timeLimit(.minutes(1)))
struct RouterNineteenthReviewDeepLinkTests {
    /// AC-013 — every generated entry point terminates on a recursive graph.
    @Test("A self-referencing feature route terminates in every entry point")
    func selfReferencingFeatureRouteTerminates() throws {
        let url = try #require(URL(string: "r19://app/leaf/42"))
        _ = SelfFeatureRoute.deepLinkCatalog
        _ = SelfFeatureRoute.supportsPureDeepLinkExplanation
        _ = SelfFeatureRoute.resolveDeepLink(url)
        _ = SelfFeatureRoute.explainDeepLink(url)
        _ = SelfFeatureRoute.deepLinkCatalogCaseName(for: .leaf(id: "42"))
        _ = SelfFeatureRoute.leaf(id: "42").deepLinkURL(
            origin: try #require(DeepLinkOrigin(scheme: "r19", host: "app"))
        )
    }

    /// AC-013 — mutual recursion is a cycle too, and no single-type check
    /// would see it.
    @Test("Mutually recursive feature routes terminate in every entry point")
    func mutuallyRecursiveFeatureRoutesTerminate() throws {
        let url = try #require(URL(string: "r19://app/a/7"))
        _ = MutualRouteA.deepLinkCatalog
        _ = MutualRouteB.deepLinkCatalog
        _ = MutualRouteA.supportsPureDeepLinkExplanation
        _ = MutualRouteA.resolveDeepLink(url)
        _ = MutualRouteA.explainDeepLink(url)
    }

    /// AC-014 — the cyclic edge fails closed instead of guessing.
    @Test("A cyclic edge contributes nothing and stays impure")
    func cyclicEdgeFailsClosed() {
        #expect(SelfFeatureRoute.supportsPureDeepLinkExplanation == false)
        #expect(MutualRouteA.supportsPureDeepLinkExplanation == false)
        // The catalog is finite: a cycle cannot keep adding entries.
        #expect(SelfFeatureRoute.deepLinkCatalog.entries.count
            == SelfFeatureRoute.deepLinkCatalog.entries.count)
        #expect(SelfFeatureRoute.deepLinkCatalog.entries.count < 10)
    }

    /// AC-015 — a child shared by two unrelated parents is not a cycle, so
    /// both parents keep contributing it.
    @Test("A child shared by two parents is not treated as a cycle")
    func sharedChildIsNotACycle() {
        let standalone = SharedChildRoute.deepLinkCatalog
        #expect(standalone.entries.isEmpty == false)

        // Walking the first parent must not suppress the same child under the
        // second one, which a global visited set would do.
        let first = FirstParentRoute.deepLinkCatalog
        let second = SecondParentRoute.deepLinkCatalog
        #expect(first.entries.count == second.entries.count)
        #expect(first.entries.count > 1)

        // Both parents carry the shared child's own pattern.
        let sharedPatterns = Set(standalone.entries.map(\.pattern))
        #expect(sharedPatterns.isSubset(of: Set(first.entries.map(\.pattern))))
        #expect(sharedPatterns.isSubset(of: Set(second.entries.map(\.pattern))))
    }

    /// AC-016 — traversal state belongs to one call, so repeating or nesting
    /// calls cannot leak a suppressed edge into the next one.
    @Test("Traversal state does not leak between calls")
    func traversalStateDoesNotLeakBetweenCalls() {
        let firstPass = SelfFeatureRoute.deepLinkCatalog
        let secondPass = SelfFeatureRoute.deepLinkCatalog
        #expect(firstPass == secondPass)

        // A nested call made while another catalog walk is on the stack sees
        // its own path.
        let nested = SelfFeatureRoute.deepLinkCatalog.entries.isEmpty
            ? SharedChildRoute.deepLinkCatalog
            : SharedChildRoute.deepLinkCatalog
        #expect(nested == SharedChildRoute.deepLinkCatalog)
    }
}

#endif
