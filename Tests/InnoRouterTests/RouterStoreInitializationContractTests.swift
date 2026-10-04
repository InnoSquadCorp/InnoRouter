import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Throwing Store initialization and unified resource admission")
@MainActor
struct RouterStoreInitializationContractTests {
    private enum R: Int, Route { case home, detail }
    private final class EmbeddingCalls: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func hit() { value.withLock { $0 += 1 } }
    }

    @Test("No-input initialization is a nonthrowing function")
    func safeEmptyStore() {
        let make: @MainActor () -> RouterStore<R> = RouterStore.init
        let store = make()
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.resourceBudget == .provisional)
        #expect(store.policyTimeout == .seconds(30))
        #expect(store.deferralConfiguration.timeToLive == .seconds(15 * 60))
    }

    @Test("Supplied paths and states reject excess without truncation")
    func suppliedInputsThrow() throws {
        let maximum = RouterResourceBudget.provisional.snapshot.maximumStackPath
        let path = Array(repeating: R.home, count: maximum + 1)
        let error = RouterResourceLimitFailure(resource: "state.stackPath", actual: maximum + 1, maximum: maximum)
        #expect(throws: error) { _ = try RouterStore(initialPath: path) }
        let state = RouterState<R>.rootStack(path: path)
        #expect(throws: error) { _ = try RouterStore(initialState: state) }
        #expect(state.root == .stack(path: path))
        let exact = try RouterStore(initialPath: Array(path.prefix(maximum)))
        #expect(exact.state.root == .stack(path: Array(path.prefix(maximum))))
        let unlimited = try RouterStore(initialState: state, configuration: .init(resourceBudget: .unlimited))
        #expect(unlimited.state == state)
    }

    @Test("Invalid supplied structure throws instead of trapping")
    func invalidStructureThrows() throws {
        var state = RouterState<R>.rootStack
        let id = UUID()
        state.windows = [.init(id: id, route: .home), .init(id: id, route: .detail)]
        #expect(throws: RouterStateValidationError.duplicateWindow) {
            _ = try RouterStore(initialState: state)
        }
    }

    @Test("Initial resource admission precedes recursive structural validation")
    func initialResourcesPrecedeStructure() throws {
        var state = RouterState<R>.rootStack
        state.root = .stack(path: [.home, .detail], presentation: .init(
            route: .home, style: .sheet, options: .init(detents: [.fraction(-1)])
        ))
        let budget = RouterResourceBudget(snapshot: try .init(maximumStackPath: 1))
        #expect(throws: RouterResourceLimitFailure(resource: "state.stackPath", actual: 2, maximum: 1)) {
            _ = try RouterStore(initialState: state, configuration: .init(resourceBudget: budget))
        }
    }

    @Test("Budget and compatibility fields preserve explicit opt-outs and overflow strategies")
    func configurationAliases() throws {
        var configuration = RouterStoreConfiguration<R>(
            resourceBudget: .unlimited,
            requestOverflowStrategy: .discardOldest,
            deferralOverflowStrategy: .cancelOldest
        )
        #expect(configuration.policyTimeout == nil)
        #expect(configuration.deferrals.timeToLive == nil)
        #expect(configuration.maximumActivePolicyOperationCount == nil)
        #expect(configuration.maximumActiveRestorationOperationCount == nil)
        configuration.maximumPendingRequestCount = 3
        configuration.deferrals.maximumPendingCount = 2
        configuration.maximumActivePolicyOperationCount = 1
        configuration.policyTimeout = .seconds(7)
        #expect(configuration.resourceBudget.maximumPendingRequests == 3)
        #expect(configuration.resourceBudget.maximumDeferrals == 2)
        #expect(configuration.resourceBudget.maximumActivePolicyOperations == 1)
        #expect(configuration.resourceBudget.policyTimeout == .seconds(7))
        #expect(configuration.resourceBudget.snapshot == RouterResourceBudget.unlimited.snapshot)
        configuration.resourceBudget = .provisional
        let store = try RouterStore(configuration: configuration)
        #expect(store.maximumPendingRequestCount == 256)
        #expect(store.policyOperations.maximumCount == 64)
        #expect(store.restorationOperations.maximumCount == 8)
        #expect(store.requestOverflowStrategy == .discardOldest)
        #expect(store.deferralConfiguration.overflowStrategy == .cancelOldest)
    }

    @Test("Legacy nil deadlines remain explicit opt-outs")
    func explicitLegacyOptOuts() throws {
        let configuration = RouterStoreConfiguration<R>(
            policyTimeout: nil, maximumActivePolicyOperationCount: nil,
            maximumActiveRestorationOperationCount: nil,
            deferrals: .init(timeToLive: nil)
        )
        let store = try RouterStore(configuration: configuration)
        #expect(store.resourceBudget.policyTimeout == nil)
        #expect(store.resourceBudget.deferralLifetime == nil)
        #expect(store.resourceBudget.maximumActivePolicyOperations == nil)
        #expect(store.resourceBudget.maximumActiveRestorationOperations == nil)
    }

    @Test("Invalid configuration values throw before normalizing or retaining state")
    func invalidConfigurationThrows() throws {
        let inputs: [(String, RouterStoreConfiguration<R>)] = [
            ("maximumPendingRequestCount", .init(maximumPendingRequestCount: -1)),
            ("deferrals.maximumPendingCount", .init(deferrals: .init(maximumPendingCount: -1))),
            ("maximumActivePolicyOperationCount", .init(maximumActivePolicyOperationCount: -1)),
            ("maximumActiveRestorationOperationCount", .init(maximumActiveRestorationOperationCount: -1)),
            ("policyTimeout", .init(policyTimeout: .seconds(-1))),
            ("deferrals.timeToLive", .init(deferrals: .init(timeToLive: .seconds(-1)))),
            ("eventBufferingPolicy", .init(eventBufferingPolicy: .bufferingNewest(-1))),
            ("eventBufferingPolicy", .init(eventBufferingPolicy: .bufferingOldest(-1))),
        ]
        for (field, configuration) in inputs {
            #expect(throws: RouterStoreConfigurationFailure(field: field)) {
                _ = try RouterStore(configuration: configuration)
            }
            #expect(throws: RouterStoreConfigurationFailure(field: field)) {
                _ = try RouterStore(initialPath: [.home], configuration: configuration)
            }
        }
        let zero = try RouterStore<R>(configuration: .init(
            maximumPendingRequestCount: 0, policyTimeout: .zero,
            maximumActivePolicyOperationCount: 0, maximumActiveRestorationOperationCount: 0,
            deferrals: .init(maximumPendingCount: 0, timeToLive: .zero),
            eventBufferingPolicy: .bufferingNewest(0)
        ))
        #expect(zero.resourceBudget.maximumPendingRequests == 0)
    }

    @Test("Shared-budget invalid input is retained until throwing Store admission")
    func invalidSharedBudgetThrows() {
        let budget = RouterResourceBudget(legacyJSONDepth: 0)
        let configuration = RouterStoreConfiguration<R>(resourceBudget: budget)
        #expect(configuration.resourceBudget.legacyJSONDepth == 0)
        #expect(throws: RouterResourceLimitFailure(
            code: .invalidConfiguration, resource: "configuration.legacyJSONDepth",
            actual: 0, maximum: .max, minimum: 1
        )) { _ = try RouterStore(configuration: configuration) }
        let negative = RouterStoreConfiguration<R>(resourceBudget: .init(maximumPendingRequests: -1))
        #expect(negative.maximumPendingRequestCount == -1)
        #expect(throws: RouterStoreConfigurationFailure(field: "maximumPendingRequestCount")) {
            _ = try RouterStore(configuration: negative)
        }
    }

    @Test("Plan builders bound final roots and preserve explicit larger budgets")
    func planBuilderResources() throws {
        let path = Array(repeating: R.home, count: 257)
        #expect(throws: RouterResourceLimitFailure(resource: "state.stackPath", actual: 257, maximum: 256)) {
            _ = try RouterPlan<R> { RouterPlanStep.root(.stack(path: path)) }
        }
        let large = try RouterPlan<R>(resourceBudget: .unlimited) {
            RouterPlanStep.root(.stack(path: path))
            RouterPlanStep.action(.push(.detail))
        }
        #expect(large.state.root == .stack(path: path + [.detail]))
    }

    @Test("Store transactions use the owning budget without reapplying provisional limits")
    func transactionUsesOwnerBudget() async throws {
        let store = try RouterStore<R>(configuration: .init(resourceBudget: .unlimited))
        let path = Array(repeating: R.home, count: 257)
        guard case .applied = try await store.transaction({ RouterPlanStep.stack(path) }) else {
            Issue.record("Expected explicit larger budget to survive plan construction")
            return
        }
        #expect(store.state.root == .stack(path: path))
        #expect(store.revision == 1)
    }

    @Test("A complete candidate is bounded before policies and commits")
    func completeCandidateRejectsAtomically() async throws {
        var calls = 0
        let budget = RouterResourceBudget(snapshot: try .init(maximumStackPath: 1))
        let store = try RouterStore<R>(initialPath: [.home], configuration: .init(
            resourceBudget: budget,
            policies: [.init(name: "must not run") { _ in calls += 1; return .allow }]
        ))
        let before = store.state
        let result = await store.perform(.push(.detail))
        guard case .rejected(_, _, _, .resourceLimit(let failure)) = result else {
            Issue.record("Expected resource-limit rejection")
            return
        }
        #expect(failure == .init(resource: "state.stackPath", actual: 2, maximum: 1))
        #expect(calls == 0)
        #expect(store.state == before)
        #expect(store.revision == 0)
        guard case .applied = await store.perform(.pop(count: 1)) else {
            Issue.record("Removing a route should recover capacity")
            return
        }
        guard case .applied = await store.perform(.push(.detail)) else {
            Issue.record("Recovered capacity should admit a route")
            return
        }
        #expect(store.revision == 2)
    }

    @Test("Deep inadmissible requests reject before observation or recursive dispatch")
    func requestAdmissionIsIterative() async throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumGraphDepth: 2))
        let store = try RouterStore<R>(configuration: .init(resourceBudget: budget))
        var observations = 0
        _ = store.addSynchronousRequestObserver { _ in observations += 1 }
        let action = RouterAction<R>.scoped("one", .scoped("two", .push(.home)))
        guard case .rejected(_, _, _, .resourceLimit(let failure)) = await store.perform(action) else {
            Issue.record("Expected scope-depth rejection before missing-container dispatch")
            return
        }
        #expect(failure.resource == "request.scopeDepth")
        #expect(observations == 0)
        #expect(store.queuedRequests.isEmpty)
        #expect(store.revision == 0)
    }

    @Test("Feature replacement checks complete resources before recursive structure")
    func featureReplacementAdmissionOrder() async throws {
        let root = try RouterNode<R>.container(.init(
            style: .tabs, selection: "one", branches: [
                .init(id: "one", node: .stack(path: [.home])), .init(id: "two"),
            ]
        ))
        let state = try RouterState(root: root)
        let budget = RouterResourceBudget(snapshot: try .init(maximumRoutes: 1))
        let invalid = RouterNode<R>.stack(presentation: .init(
            route: .detail, style: .sheet, options: .init(detents: [.fraction(-1)])
        ))
        let preparation = prepareRouterFeaturePlan(
            node: invalid, at: ["two"], in: state, resourceBudget: budget
        )
        guard case .rejected(.resourceLimit(let failure)) = preparation else {
            Issue.record("Expected complete candidate resource failure before invalid detent")
            return
        }
        #expect(failure.resource == "state.routes")
        #expect(failure.actual == 2 && failure.maximum == 1)
        let store = try RouterStore(initialState: state, configuration: .init(resourceBudget: budget))
        guard case .rejected(_, _, _, .resourceLimit) = await store.replaceSubtree(at: ["two"], with: invalid) else {
            Issue.record("Expected owner budget at subtree preparation")
            return
        }
        #expect(store.state == state)
        #expect(store.revision == 0)
    }

    @Test("Subtree replacement honors explicit larger budgets and rejects deep scope input")
    func replacementOwnerBudgetAndScope() async throws {
        let store = try RouterStore<R>(configuration: .init(resourceBudget: .unlimited))
        let path = Array(repeating: R.home, count: 257)
        guard case .applied = await store.replaceSubtree(with: .stack(path: path)) else {
            Issue.record("Expected larger Store budget to reach replacement planner")
            return
        }
        #expect(store.state.root == .stack(path: path))
        let scoped = RouterScopePath(Array(repeating: .branch("unused"), count: 32))
        #expect(throws: RouterResourceLimitFailure(resource: "request.scopeDepth", actual: 33, maximum: 32)) {
            _ = try RouterState<R>.rootStack.replacingNode(.stack(), at: scoped)
        }
    }

    @Test("Feature input admission precedes route embedding and child validation")
    func featureInputPrecedesEmbedding() async throws {
        let calls = EmbeddingCalls()
        let mapping = RouterFeatureMapping<R, R>(id: "feature", namespace: "test.feature", route: .init(
            embed: { calls.hit(); return $0 }, extract: { $0 }
        ))
        let store = try RouterStore<R>(configuration: .init(resourceBudget: .init(
            snapshot: try .init(maximumStackPath: 1)
        )))
        let feature = RouterFeatureScope(parent: store.scope(), mapping: mapping)
        guard case .rejected(_, _, _, .resourceLimit) = await feature.perform(.pushMany([.home, .detail])) else {
            Issue.record("Expected child action resource rejection before embedding")
            return
        }
        let invalid = RouterNode<R>.stack(path: [.home, .detail], presentation: .init(
            route: .home, style: .sheet, options: .init(detents: [.fraction(-1)])
        ))
        guard case .rejected(_, _, _, .resourceLimit) = await feature.performFeaturePlan(
            invalid, context: .init(), expectedRevision: nil, features: [], executionPrecondition: nil
        ) else {
            Issue.record("Expected child-plan admission before invalid detent validation")
            return
        }
        #expect(calls.count == 0)
        #expect(store.revision == 0)
        let larger = try RouterStore<R>(configuration: .init(resourceBudget: .unlimited))
        let unboundedFeature = RouterFeatureScope(parent: larger.scope(), mapping: mapping)
        let path = Array(repeating: R.home, count: 257)
        guard case .applied = await unboundedFeature.perform(.apply(.init(state: .rootStack(path: path)))) else {
            Issue.record("Expected owner opt-out to reach child plan admission")
            return
        }
        #expect(larger.state.root == .stack(path: path))
    }

    @Test("Candidate budget failure precedes invalid presentation options")
    func reducerCandidateAdmissionOrder() throws {
        let state = RouterState<R>.rootStack(path: [.home])
        let budget = RouterResourceBudget(snapshot: try .init(maximumRoutes: 1))
        let action = RouterAction<R>.present(.init(
            route: .detail, style: .sheet, options: .init(detents: [.fraction(-1)])
        ))
        #expect(throws: RouterResourceLimitFailure(resource: "state.routes", actual: 2, maximum: 1)) {
            _ = try RouterReducer.reduce(action, from: state, resourceBudget: budget)
        }
    }
}
