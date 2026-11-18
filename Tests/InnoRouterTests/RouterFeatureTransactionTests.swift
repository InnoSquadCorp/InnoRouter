import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum TransactionChildRoute: String, Route, Codable {
    case home, detail
}

private enum TransactionParentRoute: Hashable, Route, Codable {
    case feature(TransactionChildRoute)
    case other
}

private enum TransactionOuterRoute: Hashable, Route, Codable {
    case parent(TransactionParentRoute)
}

private let childMapping = RouterFeatureMapping<TransactionParentRoute, TransactionChildRoute>(
    id: "feature",
    namespace: "TransactionParentRoute.feature",
    route: .init(
        embed: TransactionParentRoute.feature,
        extract: {
            guard case .feature(let child) = $0 else { return nil }
            return child
        }
    )
)

private let parentMapping = RouterFeatureMapping<TransactionOuterRoute, TransactionParentRoute>(
    id: "parent",
    namespace: "TransactionOuterRoute.parent",
    route: .init(
        embed: TransactionOuterRoute.parent,
        extract: {
            guard case .parent(let parent) = $0 else { return nil }
            return parent
        }
    )
)

/// A transaction made through a feature projection applies its steps to the
/// feature's subtree as the Store holds it when the request runs. 7.0 built
/// the subtree when the call was made and replaced it when the request ran,
/// which silently reverted every request that executed in between.
@Suite("Feature transactions", .serialized)
@MainActor
struct RouterFeatureTransactionTests {
    private func makeFeature(
        _ timing: RouterDispatchTiming
    ) throws -> (RouterStore<TransactionParentRoute>, RouterActions<TransactionChildRoute>) {
        var configuration = RouterStoreConfiguration<TransactionParentRoute>()
        configuration.dispatchTiming = timing
        let store = try RouterStore<TransactionParentRoute>(
            initialState: .rootStack(path: [.feature(.home)]), configuration: configuration
        )
        let feature = RouterFeatureScope(parent: store.scope(), mapping: childMapping)
        return (store, RouterActions(authority: .init(base: feature)))
    }

    @Test("A feature transaction builds on the requests made before it", arguments: [
        RouterDispatchTiming.deferred, .immediateWhenIdle,
    ])
    func followsEarlierRequests(timing: RouterDispatchTiming) async throws {
        let (store, router) = try makeFeature(timing)

        router.go(.detail)
        let transaction = try router.transaction {
            RouterPlanStep.presentation(.init(route: .home, style: .sheet))
        }

        guard case .applied = await transaction.value else {
            Issue.record("The feature transaction did not apply after an earlier request")
            return
        }
        guard case .stack(let stack) = store.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        #expect(stack.path == [.feature(.home), .feature(.detail)], "The transaction reverted the earlier push")
        #expect(stack.presentation?.route == .feature(.home))
        #expect(store.revision == 2)
    }

    @Test("A feature transaction that conflicts with an earlier request never reverts it")
    func conflictingTransactionIsRejected() async throws {
        let (store, router) = try makeFeature(.deferred)

        router.sheet(.detail)
        // Valid at the call, before the sheet commits.
        let transaction = try router.transaction {
            RouterPlanStep.action(.push(.detail))
        }

        guard case .rejected(_, _, _, .mutation) = await transaction.value else {
            Issue.record("A push under the earlier sheet was not rejected")
            return
        }
        guard case .stack(let stack) = store.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        #expect(stack.path == [.feature(.home)])
        #expect(stack.presentation?.route == .feature(.detail), "The transaction removed the earlier sheet")
        #expect(store.revision == 1)
    }

    @Test("A nested feature transaction builds on the requests made before it")
    func nestedFeatureFollowsEarlierRequests() async throws {
        let store = try RouterStore<TransactionOuterRoute>(
            initialState: .rootStack(path: [.parent(.feature(.home))])
        )
        let parent = RouterFeatureScope(parent: store.scope(), mapping: parentMapping)
        let child = RouterFeatureScope(
            parent: parent as any RouterAuthorityProtocol<TransactionParentRoute>, mapping: childMapping
        )
        let router = RouterActions(authority: .init(base: child))

        router.go(.detail)
        let transaction = try router.transaction {
            RouterPlanStep.presentation(.init(route: .home, style: .sheet))
        }

        guard case .applied = await transaction.value else {
            Issue.record("The nested feature transaction did not apply")
            return
        }
        guard case .stack(let stack) = store.state.root else {
            Issue.record("Expected a root stack")
            return
        }
        #expect(stack.path == [.parent(.feature(.home)), .parent(.feature(.detail))])
        #expect(stack.presentation?.route == .parent(.feature(.home)))
    }

    @Test("A feature transaction rejects a subtree the feature no longer owns")
    func transactionAfterLosingTheSubtreeIsRejected() async throws {
        let (store, router) = try makeFeature(.deferred)

        // Runs first and leaves a route the feature does not own.
        store.dispatch(.push(.other))
        let transaction = try router.transaction {
            RouterPlanStep.action(.push(.detail))
        }

        guard case .rejected(_, _, _, .featureProjection(.routeMismatch)) = await transaction.value else {
            Issue.record("The transaction replaced a subtree the feature no longer owns")
            return
        }
        #expect(store.state.root == .stack(path: [.feature(.home), .other]))
        #expect(store.revision == 1)
    }
}
