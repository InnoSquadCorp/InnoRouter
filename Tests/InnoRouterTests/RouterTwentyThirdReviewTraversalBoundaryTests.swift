import Foundation
import Synchronization
import Testing

import InnoRouterDeepLink

private final class TwentyThirdTraversalFixture: Sendable {
    private struct State {
        var activeDepth = 0
        var visits = 0
    }
    private let state = Mutex(State())
    let depth: Int
    let branches: Int

    init(depth: Int, branches: Int = 1) {
        self.depth = depth
        self.branches = branches
    }

    var visits: Int { state.withLock { $0.visits } }
    var activeDepth: Int { state.withLock { $0.activeDepth } }

    func enter() -> Bool {
        state.withLock {
            $0.visits += 1
            $0.activeDepth += 1
            return $0.activeDepth < depth
        }
    }

    func leave() { state.withLock { $0.activeDepth -= 1 } }
}

private enum TwentyThirdTraversalShape {
    @TaskLocal static var fixture: TwentyThirdTraversalFixture?
}

// A finite handwritten contract using the same root/bridge protocol as the
// macro. Each depth changes the concrete specialization; sibling edges reuse
// it only after leaving the previous edge. Returning one terminal value keeps
// budget accounting separate from generated URL ambiguity/round-trip work.
private enum TwentyThirdBoundaryRoute<Value: Hashable & Sendable>: DeepLinkRoute {
    case leaf

    private typealias Child = TwentyThirdBoundaryRoute<[Value]>
    private static var leafURL: URL { URL(string: "r23://app/leaf")! }

    private static func traverse<Output>(
        leaf: () -> Output,
        child: () -> Output
    ) -> Output {
        guard let fixture = TwentyThirdTraversalShape.fixture else { return leaf() }
        let descends = fixture.enter()
        defer { fixture.leave() }
        var result = leaf()
        guard descends else { return result }
        for _ in 0 ..< fixture.branches {
            result = child()
        }
        return result
    }

    static var deepLinkCatalog: DeepLinkRouteCatalog {
        DeepLinkFeatureRuntime.catalog(for: Self.self) {
            traverse {
                .init(schemes: ["r23"], hosts: ["app"], entries: [.init(routeCase: "leaf", pattern: "/leaf")])
            } child: {
                DeepLinkFeatureRuntime.catalog(for: Child.self)
            }
        }
    }

    static var supportsPureDeepLinkExplanation: Bool {
        DeepLinkFeatureRuntime.supportsPureExplanation(for: Self.self) {
            traverse { true } child: { DeepLinkFeatureRuntime.supportsPureExplanation(for: Child.self) }
        }
    }

    static func resolveDeepLink(_ url: URL) -> Self? {
        DeepLinkFeatureRuntime.resolve(Self.self, url: url) {
            traverse { url == leafURL ? Self.leaf : nil } child: {
                DeepLinkFeatureRuntime.resolve(Child.self, url: url).map { _ in Self.leaf }
            }
        }
    }

    static func deepLinkCatalogCaseName(for route: Self) -> String? {
        DeepLinkFeatureRuntime.caseName(for: route) {
            traverse { "leaf" } child: { DeepLinkFeatureRuntime.caseName(for: Child.leaf) }
        }
    }

    func deepLinkURL(origin: DeepLinkOrigin) -> URL? {
        DeepLinkFeatureRuntime.url(for: self, origin: origin) {
            Self.traverse { Self.leafURL } child: { DeepLinkFeatureRuntime.url(for: Child.leaf, origin: origin) }
        }
    }
}

@Suite("Twenty-third review production traversal boundaries")
struct RouterTwentyThirdReviewTraversalBoundaryTests {
    enum Operation: CaseIterable, Sendable {
        case catalog, purity, resolve, caseName, url
    }

    @Test("Production depth includes the root exactly once", arguments: [63, 64, 65], Operation.allCases)
    func depthBoundary(depth: Int, operation: Operation) {
        let fixture = TwentyThirdTraversalFixture(depth: depth)
        TwentyThirdTraversalShape.$fixture.withValue(fixture) {
            verify(operation, succeeds: depth <= 64)
        }
        #expect(fixture.visits == min(depth, 64))
        #expect(fixture.activeDepth == 0)
        verify(operation, succeeds: true)
    }

    @Test("Production entry budget includes root and every sibling", arguments: [1_023, 1_024, 1_025], Operation.allCases)
    func entryBoundary(attempts: Int, operation: Operation) {
        let fixture = TwentyThirdTraversalFixture(depth: 2, branches: attempts - 1)
        TwentyThirdTraversalShape.$fixture.withValue(fixture) {
            verify(operation, succeeds: attempts <= 1_024)
        }
        #expect(fixture.visits == min(attempts, 1_024))
        #expect(fixture.activeDepth == 0)
        verify(operation, succeeds: true)
    }

    private func verify(_ operation: Operation, succeeds: Bool) {
        typealias R = TwentyThirdBoundaryRoute<Int>
        let url = URL(string: "r23://app/leaf")!
        switch operation {
        case .catalog:
            let catalog = R.deepLinkCatalog
            #expect(catalog.isComplete == succeeds)
            #expect(catalog.entries.map(\.routeCase) == (succeeds ? ["leaf"] : []))
        case .purity:
            #expect(R.supportsPureDeepLinkExplanation == succeeds)
        case .resolve:
            #expect(R.resolveDeepLink(url) == (succeeds ? .leaf : nil))
        case .caseName:
            #expect(R.deepLinkCatalogCaseName(for: .leaf) == (succeeds ? "leaf" : nil))
        case .url:
            #expect(R.leaf.deepLinkURL(origin: DeepLinkOrigin(scheme: "r23", host: "app")!) == (succeeds ? url : nil))
        }
    }
}
