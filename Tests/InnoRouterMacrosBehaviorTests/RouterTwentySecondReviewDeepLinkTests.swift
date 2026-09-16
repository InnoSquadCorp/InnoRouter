// MARK: - RouterTwentySecondReviewDeepLinkTests.swift
// InnoRouterMacrosBehaviorTests - bounded generated feature traversal

#if canImport(InnoRouterMacrosPlugin)

import Foundation
import SwiftUI
import Testing

import InnoRouterDeepLink
import InnoRouterMacros

@Router(deepLinkSchemes: ["r22"], deepLinkHosts: ["app"], inspectorCatalog: true)
private indirect enum TwentySecondSelfRoute {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(Self)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["r22"], deepLinkHosts: ["app"], inspectorCatalog: true)
private enum TwentySecondSharedLeafRoute {
    @DeepLink("/shared/:id")
    case leaf(id: String)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["r22"], deepLinkHosts: ["app"], inspectorCatalog: true)
private enum TwentySecondSiblingRoute {
    @FeatureRoute
    case left(TwentySecondSharedLeafRoute)

    @FeatureRoute
    case right(TwentySecondSharedLeafRoute)

    var destination: some View { EmptyView() }
}

@Router(deepLinkSchemes: ["r22"], deepLinkHosts: ["app"], inspectorCatalog: true)
private indirect enum TwentySecondExpandingRoute<Value: Hashable & Sendable> {
    @DeepLink("/leaf/:id")
    case leaf(id: String)

    @FeatureRoute
    case child(TwentySecondExpandingRoute<[Value]>)

    var destination: some View { EmptyView() }
}

@Suite("Twenty-second review bounded deep links")
struct RouterTwentySecondReviewDeepLinkTests {
    private let origin = DeepLinkOrigin(scheme: "r22", host: "app")!

    @Test("A self feature excludes its cyclic edge and keeps its local leaf")
    func selfFeaturePreservesLocalLeaf() throws {
        let url = try #require(URL(string: "r22://app/leaf/42"))
        #expect(TwentySecondSelfRoute.deepLinkCatalog.isComplete)
        #expect(TwentySecondSelfRoute.deepLinkCatalog.entries.map(\.routeCase) == ["leaf"])
        #expect(TwentySecondSelfRoute.resolveDeepLink(url) == .leaf(id: "42"))
        #expect(
            TwentySecondSelfRoute.leaf(id: "42").deepLinkURL(origin: origin) == url
        )
        #expect(
            TwentySecondSelfRoute.deepLinkCatalogCaseName(
                for: .child(.leaf(id: "42"))
            ) == nil
        )
        #expect(
            TwentySecondSelfRoute.child(.leaf(id: "42")).deepLinkURL(origin: origin) == nil
        )
        #expect(TwentySecondSelfRoute.supportsPureDeepLinkExplanation == false)
    }

    @Test("Sibling feature paths sharing one child are both preserved")
    func siblingFeaturesAreNotCycles() throws {
        let catalog = TwentySecondSiblingRoute.deepLinkCatalog
        #expect(catalog.isComplete)
        #expect(Set(catalog.entries.map(\.routeCase)) == ["left.leaf", "right.leaf"])
        #expect(catalog.entries.count == 2)

        let sharedURL = try #require(URL(string: "r22://app/shared/7"))
        #expect(TwentySecondSiblingRoute.resolveDeepLink(sharedURL) == nil)
        #expect(
            TwentySecondSiblingRoute.deepLinkCatalogCaseName(
                for: .left(.leaf(id: "7"))
            ) == "left.leaf"
        )
        #expect(
            TwentySecondSiblingRoute.deepLinkCatalogCaseName(
                for: .right(.leaf(id: "7"))
            ) == "right.leaf"
        )
        #expect(
            TwentySecondSiblingRoute.left(.leaf(id: "7")).deepLinkURL(origin: origin) == nil
        )
    }

    @Test("Growing generic specializations fail closed at the traversal limit")
    func growingGenericSpecializationsAreBounded() throws {
        typealias G0 = TwentySecondExpandingRoute<Int>
        typealias G1 = TwentySecondExpandingRoute<[Int]>
        typealias G2 = TwentySecondExpandingRoute<[[Int]]>
        typealias G3 = TwentySecondExpandingRoute<[[[Int]]]>

        let route: G0 = .child(G1.child(G2.child(G3.leaf(id: "42"))))
        let url = try #require(URL(string: "r22://app/leaf/42"))
        let limits = DeepLinkTraversalLimits(maximumDepth: 3, maximumEntryAttempts: 32)

        DeepLinkTraversalTestSupport.withLimits(limits) {
            let catalog = G0.deepLinkCatalog
            #expect(catalog.isComplete == false)
            #expect(catalog.entries.isEmpty)
            #expect(G0.supportsPureDeepLinkExplanation == false)
            #expect(G0.resolveDeepLink(url) == nil)
            #expect(G0.deepLinkCatalogCaseName(for: route) == nil)
            #expect(route.deepLinkURL(origin: origin) == nil)
            #expect(
                G0.explainDeepLink(url).decision
                    == .rejected(.traversalLimitExceeded)
            )
        }

        // The traversal limit does not outlaw recursive route values.
        #expect(route == route)
    }

    @Test("The total entry budget rejects a partial sibling catalog")
    func entryBudgetRejectsPartialCatalog() {
        #expect(DeepLinkTraversalLimits.production.maximumDepth == 64)
        #expect(DeepLinkTraversalLimits.production.maximumEntryAttempts == 1_024)

        let depthLimited = DeepLinkTraversalTestSupport.withLimits(
            .init(maximumDepth: 1, maximumEntryAttempts: 32)
        ) {
            TwentySecondSiblingRoute.deepLinkCatalog
        }
        #expect(!depthLimited.isComplete)

        let depthBoundary = DeepLinkTraversalTestSupport.withLimits(
            .init(maximumDepth: 2, maximumEntryAttempts: 32)
        ) {
            TwentySecondSiblingRoute.deepLinkCatalog
        }
        #expect(depthBoundary.isComplete)
        #expect(depthBoundary.entries.count == 2)

        let incomplete = DeepLinkTraversalTestSupport.withLimits(
            .init(maximumDepth: 64, maximumEntryAttempts: 2)
        ) {
            TwentySecondSiblingRoute.deepLinkCatalog
        }
        #expect(incomplete.isComplete == false)
        #expect(incomplete.entries.isEmpty)

        let complete = DeepLinkTraversalTestSupport.withLimits(
            .init(maximumDepth: 64, maximumEntryAttempts: 3)
        ) {
            TwentySecondSiblingRoute.deepLinkCatalog
        }
        #expect(complete.isComplete)
        #expect(complete.entries.count == 2)
    }

    @Test("A limited traversal never contaminates the next call")
    func traversalContextDoesNotLeak() {
        let incomplete = DeepLinkTraversalTestSupport.withLimits(
            .init(maximumDepth: 1, maximumEntryAttempts: 1)
        ) {
            TwentySecondSiblingRoute.deepLinkCatalog
        }
        #expect(incomplete.isComplete == false)

        let next = TwentySecondSiblingRoute.deepLinkCatalog
        #expect(next.isComplete)
        #expect(next.entries.count == 2)
    }

    @Test("Concurrent roots own independent traversal contexts")
    func concurrentRootsAreIndependent() async throws {
        let url = try #require(URL(string: "r22://app/shared/7"))
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    let catalog = TwentySecondSiblingRoute.deepLinkCatalog
                    return catalog.isComplete
                        && catalog.entries.count == 2
                        && TwentySecondSiblingRoute.resolveDeepLink(url) == nil
                }
            }
            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0 })
    }
}

#endif
