import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

/// Synthetic boundary fixtures, not calibrated application workloads or a claim
/// that every Store/codec/initializer already enforces this configuration.
@Suite("Unified resource budget structure boundaries")
struct RouterResourceBudgetPortableContractTests {
    private enum R: Int, Route { case home, detail }

    private final class Calls: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func hit() { value.withLock { $0 += 1 } }
    }

    private struct ObservedRoute: Route {
        let calls: Calls
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.calls.hit()
            return lhs.calls === rhs.calls
        }
        func hash(into hasher: inout Hasher) {
            calls.hit()
            hasher.combine(0)
        }
    }

    private func container(_ nodes: [RouterNode<R>]) throws -> RouterNode<R> {
        let branches = nodes.enumerated().map { RouterBranch<R>(id: .init(rawValue: "b\($0.offset)"), node: $0.element) }
        return .container(try .init(style: .tabs, selection: branches.first?.id, branches: branches))
    }

    private func chain(depth: Int) throws -> RouterNode<R> {
        var node = RouterNode<R>.stack()
        for _ in 1..<depth { node = try container([node]) }
        return node
    }

    private func expectLimit(_ resource: String, actual: Int, maximum: Int, operation: () throws -> Void) {
        #expect(throws: RouterResourceLimitFailure(resource: resource, actual: actual, maximum: maximum)) {
            try operation()
        }
    }

    @Test("Draft defaults accept a path boundary and reject boundary plus one")
    func pathBoundary() throws {
        let maximum = RouterResourceBudget.provisional.snapshot.maximumStackPath
        let exact = RouterStateDraft<R>(root: .stack(path: Array(repeating: .home, count: maximum)))
        let build: () throws -> RouterState<R> = exact.build
        #expect(try build().root == exact.root)
        let excess = RouterStateDraft<R>(root: .stack(path: Array(repeating: .home, count: maximum + 1)))
        expectLimit("state.stackPath", actual: maximum + 1, maximum: maximum) { _ = try excess.build() }
        #expect(excess.root == .stack(path: Array(repeating: .home, count: maximum + 1)))
        let larger = RouterResourceBudget(snapshot: try .init(maximumStackPath: maximum + 1))
        #expect(try excess.build(resourceBudget: larger).root == excess.root)
        #expect(try excess.build(resourceBudget: .unlimited).root == excess.root)
    }

    @Test("All sibling nodes count, including unselected branches, and removal recovers capacity")
    func nodeBoundaryAndRecovery() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumNodes: 3))
        var draft = try RouterStateDraft<R>(root: container([.stack(), .stack(), .stack()]))
        expectLimit("state.nodes", actual: 4, maximum: 3) { _ = try draft.build(resourceBudget: budget) }
        draft.root = try container([.stack(), .stack()])
        #expect(try draft.build(resourceBudget: budget).root == draft.root)
        // Validation does not retain capacity across successive calls.
        #expect(try draft.build(resourceBudget: budget).root == draft.root)
    }

    @Test("The provisional node count accepts its exact boundary and rejects one extra sibling")
    func provisionalNodeBoundary() throws {
        let maximum = RouterResourceBudget.provisional.snapshot.maximumNodes
        let exact = try RouterStateDraft<R>(root: container(Array(repeating: .stack(), count: maximum - 1)))
        _ = try exact.build()
        let excess = try RouterStateDraft<R>(root: container(Array(repeating: .stack(), count: maximum)))
        expectLimit("state.nodes", actual: maximum + 1, maximum: maximum) { _ = try excess.build() }
    }

    @Test("A deep draft is rejected iteratively before recursive state validation")
    func deepDraftAdmission() throws {
        let maximum = RouterResourceBudget.provisional.snapshot.maximumGraphDepth
        _ = try RouterStateDraft(root: chain(depth: maximum)).build()
        expectLimit("state.graphDepth", actual: maximum + 1, maximum: maximum) {
            _ = try RouterStateDraft(root: chain(depth: maximum + 1)).build()
        }
        let deep = try RouterStateDraft(root: chain(depth: 512))
        expectLimit("state.graphDepth", actual: maximum + 1, maximum: maximum) { _ = try deep.build() }
    }

    @Test("Graph depth and presentation depth are separate, and scene roots restart both")
    func presentationBoundary() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPresentationDepth: 1))
        let first = RouterPresentation<R>(route: .home, style: .sheet, node: .stack())
        try budget.validate(root: RouterNode<R>.stack(presentation: first))
        let nested = RouterPresentation<R>(route: .home, style: .sheet, node: .stack(presentation: first))
        expectLimit("state.presentationDepth", actual: 2, maximum: 1) {
            try budget.validate(root: RouterNode<R>.stack(presentation: nested))
        }
        let window = RouterWindow<R>(route: .home, node: .stack(presentation: .init(route: .detail, style: .sheet)))
        let space = RouterImmersiveSpace<R>(id: "space", route: .home, node: .stack(presentation: .init(route: .detail, style: .sheet)))
        _ = try RouterStateDraft(root: RouterNode<R>.stack(presentation: first), windows: [window], immersiveSpace: space)
            .build(resourceBudget: budget)
    }

    @Test("Presentation count is global even when no presentation is nested")
    func presentationCount() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPresentations: 2))
        let nodes: [RouterNode<R>] = (0..<3).map { _ in .stack(presentation: .init(route: .home, style: .sheet)) }
        _ = try RouterStateDraft(root: container(Array(nodes.prefix(2)))).build(resourceBudget: budget)
        expectLimit("state.presentations", actual: 3, maximum: 2) {
            _ = try RouterStateDraft(root: container(nodes)).build(resourceBudget: budget)
        }
    }

    @Test("Window and immersive roots and their routes share the whole-state budget")
    func windowsAndRoutes() throws {
        let one = RouterWindow<R>(route: .home)
        let two = RouterWindow<R>(route: .detail)
        let budget = RouterResourceBudget(snapshot: try .init(maximumRoutes: 2, maximumWindows: 1))
        try budget.validate(root: RouterNode<R>.stack(path: [.home]), windows: [one])
        expectLimit("state.windows", actual: 2, maximum: 1) {
            try budget.validate(root: RouterNode<R>.stack(), windows: [one, two])
        }
        let carryingPath = RouterWindow<R>(route: .home, node: .stack(path: [.detail]))
        expectLimit("state.routes", actual: 3, maximum: 2) {
            try budget.validate(root: RouterNode<R>.stack(path: [.home]), windows: [carryingPath])
        }
        let space = RouterImmersiveSpace<R>(id: "space", route: .detail)
        try budget.validate(root: RouterNode<R>.stack(), windows: [one], immersiveSpace: space)
        expectLimit("state.routes", actual: 3, maximum: 2) {
            try budget.validate(root: RouterNode<R>.stack(path: [.home]), windows: [one], immersiveSpace: space)
        }
        let nodeBudget = RouterResourceBudget(snapshot: try .init(maximumNodes: 2))
        expectLimit("state.nodes", actual: 3, maximum: 2) {
            try nodeBudget.validate(root: RouterNode<R>.stack(), windows: [one], immersiveSpace: space)
        }
    }

    @Test("Runtime counts agree with emitted flat graph records across all domains")
    func graphCounterParity() throws {
        let limits = try RouterGraphSnapshotLimits(
            maximumNodes: 6, maximumRoutes: 9, maximumPresentations: 1,
            maximumGraphDepth: 3, maximumStackPath: 2, maximumPresentationDepth: 1, maximumWindows: 1
        )
        let root = try container([
            .stack(path: [.home], presentation: .init(route: .detail, style: .sheet, node: .stack(path: [.home]))),
            .stack(path: [.home, .detail]),
        ])
        let state = try RouterStateDraft(
            root: root,
            windows: [RouterWindow<R>(route: .home, node: .stack(path: [.detail]))],
            immersiveSpace: RouterImmersiveSpace<R>(id: "space", route: .home, node: .stack(path: [.detail]))
        ).build(resourceBudget: .init(snapshot: limits))
        let routes = try RouterGraphRouteCodec<R>(supportedPayloadVersions: ["route": 1]) { route in
            .init(stableKey: "route", payloadVersion: 1, data: Data([UInt8(route.rawValue)]))
        } decode: { payload in
            payload.data.first == 1 ? .detail : .home
        }
        let codec = try RouterGraphSnapshotCodec(schemaID: "budget.parity", schemaVersion: 1, routes: routes, limits: limits)
        let envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: codec.encode(state))
        let graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: envelope.payload)
        #expect(graph.nodes.count == 6)
        #expect(graph.routes.count == 9)
        #expect(graph.presentations.count == 1)
        #expect(graph.windows.count == 1)
        #expect(graph.immersiveSpace != nil)
        #expect(try codec.decode(codec.encode(state)) == state)
        expectLimit("state.routes", actual: 9, maximum: 8) {
            try RouterResourceBudget(snapshot: .init(maximumRoutes: 8)).validate(state)
        }
        expectLimit("state.nodes", actual: 6, maximum: 5) {
            try RouterResourceBudget(snapshot: .init(maximumNodes: 5)).validate(state)
        }
    }

    @Test("Request arrays honor both path and total-route caps before reduction")
    func actionAdmission() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumGraphDepth: 2, maximumStackPath: 2))
        try budget.validateInput(RouterAction<R>.pushMany([.home, .detail]))
        expectLimit("state.stackPath", actual: 3, maximum: 2) {
            try budget.validateInput(RouterAction<R>.pushMany([.home, .detail, .home]))
        }
        expectLimit("request.scopeDepth", actual: 3, maximum: 2) {
            try budget.validateInput(RouterAction<R>.scoped("one", .scoped("two", .push(.home))))
        }
        let routes = RouterResourceBudget(snapshot: try .init(maximumRoutes: 1, maximumStackPath: 2))
        for action in [RouterAction<R>.pushMany([.home, .detail]), .replaceStack([.home, .detail])] {
            expectLimit("state.routes", actual: 2, maximum: 1) { try routes.validateInput(action) }
        }
    }

    @Test("Scene action input includes the scene route and unavoidable application root")
    func sceneActionAdmission() throws {
        let window = RouterWindow<R>(route: .home, node: .stack(path: [.detail]))
        let space = RouterImmersiveSpace<R>(id: "space", route: .home, node: .stack(path: [.detail]))
        let exact = RouterResourceBudget(snapshot: try .init(maximumNodes: 2, maximumRoutes: 2))
        let nodes = RouterResourceBudget(snapshot: try .init(maximumNodes: 1))
        let routes = RouterResourceBudget(snapshot: try .init(maximumRoutes: 1))
        for action in [RouterAction<R>.openWindow(window), .enterImmersiveSpace(space)] {
            try exact.validateInput(action)
            expectLimit("state.nodes", actual: 2, maximum: 1) { try nodes.validateInput(action) }
            expectLimit("state.routes", actual: 2, maximum: 1) { try routes.validateInput(action) }
        }
    }

    @Test("Outer scene selectors do not consume node depth; repeated malformed selectors remain bounded")
    func sceneScopeDepth() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumGraphDepth: 1))
        try budget.validateInput(RouterAction<R>.windowScoped(UUID(), .push(.home)))
        try budget.validateInput(RouterAction<R>.immersiveSpaceScoped("space", .push(.home)))
        expectLimit("request.scopeDepth", actual: 2, maximum: 1) {
            try budget.validateInput(RouterAction<R>.windowScoped(UUID(), .scoped("child", .push(.home))))
        }
        var action = RouterAction<R>.push(.home)
        for _ in 0..<512 { action = .windowScoped(UUID(), action) }
        expectLimit("request.scopeDepth", actual: 2, maximum: 1) { try budget.validateInput(action) }
    }

    @Test("Plan and presentation requests receive the same structural admission")
    func planAndPresentationAdmission() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumNodes: 1, maximumStackPath: 1))
        let state = try RouterStateDraft<R>(root: .stack(path: [.home, .detail])).build()
        expectLimit("state.stackPath", actual: 2, maximum: 1) {
            try budget.validateInput(RouterAction<R>.apply(.init(state: state)))
        }
        expectLimit("state.nodes", actual: 2, maximum: 1) {
            try budget.validateInput(RouterAction<R>.present(.init(route: .home, style: .sheet)))
        }
    }

    @Test("Repeated Unicode ID occurrences and custom names consume metadata bytes")
    func metadataByteBoundary() throws {
        var node = try RouterContainerState<R>(
            style: .custom("x"), selection: "é", branches: [.init(id: "é")], badges: ["é": 1]
        )
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 7))
        _ = try RouterStateDraft(root: RouterNode<R>.container(node)).build(resourceBudget: budget)
        node.style = .custom("xx")
        expectLimit("state.metadataBytes", actual: 8, maximum: 7) {
            _ = try RouterStateDraft(root: RouterNode<R>.container(node)).build(resourceBudget: budget)
        }
        let bytes = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 2))
        try bytes.validate(root: RouterNode<R>.container(.init(style: .custom("é"), branches: [])))
        expectLimit("state.metadataBytes", actual: 3, maximum: 2) {
            try bytes.validate(root: RouterNode<R>.container(.init(style: .custom("e\u{301}"), branches: [])))
        }
    }

    @Test("Split references and immersive IDs are included in repeated metadata bytes")
    func splitAndSceneMetadata() throws {
        let root = try RouterNode<R>.container(.init(
            style: .split, selection: "s",
            branches: [.init(id: "s"), .init(id: "c"), .init(id: "d")], badges: ["d": 1],
            split: .init(sidebar: "s", content: "c", detail: "d")
        ))
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 9))
        var draft = RouterStateDraft(root: root, immersiveSpace: .init(id: "i", route: .home))
        _ = try draft.build(resourceBudget: budget)
        draft.immersiveSpace?.id = "ii"
        expectLimit("state.metadataBytes", actual: 10, maximum: 9) { _ = try draft.build(resourceBudget: budget) }
    }

    @Test("Metadata byte rejection precedes structural hashing and preserves invalid draft input")
    func metadataBeforeStructuralValidation() throws {
        var node = try RouterContainerState<R>(style: .tabs, selection: "a", branches: [.init(id: "a")])
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 2))
        _ = try RouterStateDraft(root: RouterNode<R>.container(node)).build(resourceBudget: budget)
        node.branches.append(.init(id: "a"))
        let invalid = RouterStateDraft(root: RouterNode<R>.container(node))
        expectLimit("state.metadataBytes", actual: 3, maximum: 2) { _ = try invalid.build(resourceBudget: budget) }
        #expect(invalid.root == .container(node))
        #expect(throws: RouterStateValidationError.duplicateScope) {
            try invalid.build(resourceBudget: .init(snapshot: .init(maximumPayloadBytes: 3)))
        }
    }

    @Test("Detent collections, selected detents and background detents share an aggregate element cap")
    func detentElementBoundary() throws {
        var presentation = RouterPresentation<R>(
            route: .home, style: .sheet,
            options: .init(detents: [.medium, .large], selectedDetent: .medium, backgroundInteraction: .enabledUpThrough(.large))
        )
        let budget = RouterResourceBudget(snapshot: try .init(maximumJSONTokens: 4))
        _ = try RouterStateDraft(root: RouterNode<R>.stack(presentation: presentation)).build(resourceBudget: budget)
        presentation.options.detents.append(.height(100))
        expectLimit("state.metadataElements", actual: 5, maximum: 4) {
            _ = try RouterStateDraft(root: RouterNode<R>.stack(presentation: presentation)).build(resourceBudget: budget)
        }
        presentation.options = .init(detents: [.height(-1), .large])
        let invalid = RouterStateDraft(root: RouterNode<R>.stack(presentation: presentation))
        expectLimit("state.metadataElements", actual: 2, maximum: 1) {
            _ = try invalid.build(resourceBudget: .init(snapshot: .init(maximumJSONTokens: 1)))
        }
        #expect(throws: RouterStateValidationError.invalidPresentationDetent(.height(-1))) {
            try invalid.build(resourceBudget: .init(snapshot: .init(maximumJSONTokens: 2)))
        }
    }

    @Test("Badge admission precedes dictionary traversal and aggregates with other nodes' detents")
    func badgeElementBoundary() throws {
        var node = try RouterContainerState<R>(
            style: .tabs, selection: "a", branches: [.init(id: "a"), .init(id: "b")], badges: ["a": 1, "b": 1]
        )
        let budget = RouterResourceBudget(snapshot: try .init(maximumJSONTokens: 2))
        _ = try RouterStateDraft(root: RouterNode<R>.container(node)).build(resourceBudget: budget)
        node.badges["unknown"] = 1
        expectLimit("state.metadataElements", actual: 3, maximum: 2) {
            _ = try RouterStateDraft(root: RouterNode<R>.container(node)).build(resourceBudget: budget)
        }
        node.badges = ["a": 1]
        node.branches[0].node = .stack(presentation: .init(
            route: .home, style: .sheet, options: .init(detents: [.medium, .large])
        ))
        expectLimit("state.metadataElements", actual: 3, maximum: 2) {
            _ = try RouterStateDraft(root: RouterNode<R>.container(node)).build(resourceBudget: budget)
        }
        _ = try RouterStateDraft(root: RouterNode<R>.container(node))
            .build(resourceBudget: .init(snapshot: .init(maximumJSONTokens: 3)))
    }

    @Test("Request selectors share metadata admission before equality or hash dispatch")
    func requestMetadataAdmission() throws {
        let exact = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 4))
        let excess = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 3))
        let actions: [RouterAction<R>] = [
            .scoped("ab", .select("cd")),
            .immersiveSpaceScoped("ab", .setBadge(1, for: "cd")),
            .select("abcd"), .setBadge(nil, for: "abcd"),
        ]
        for action in actions {
            try exact.validateInput(action)
            expectLimit("state.metadataBytes", actual: 4, maximum: 3) { try excess.validateInput(action) }
        }
    }

    @Test("Graph encoding rejects oversized metadata before invoking application route encoding")
    func graphMetadataAdmissionPrecedesApplicationCodec() throws {
        let nameState = try RouterStateDraft(root: RouterNode<R>.container(.init(
            style: .custom("123456789"), branches: [.init(id: "a", node: .stack(path: [.home]))]
        ))).build()
        let detentState = try RouterStateDraft(root: RouterNode<R>.stack(presentation: .init(
            route: .home, style: .sheet, options: .init(detents: [.medium, .large, .height(100)])
        ))).build()
        let fixtures: [(RouterState<R>, RouterGraphSnapshotLimits, RouterGraphSnapshotError)] = [
            (nameState, try .init(maximumPayloadBytes: 9), .limitExceeded(name: "metadataBytes", actual: 10, maximum: 9)),
            (detentState, try .init(maximumJSONTokens: 2), .limitExceeded(name: "metadataElements", actual: 3, maximum: 2)),
        ]
        for (state, limits, failure) in fixtures {
            let calls = Calls()
            let routes = try RouterGraphRouteCodec<R>(supportedPayloadVersions: ["home": 1]) { _ in
                calls.hit()
                return .init(stableKey: "home", payloadVersion: 1, data: Data())
            } decode: { _ in .home }
            let normal = try RouterGraphSnapshotCodec(schemaID: "metadata.control", schemaVersion: 1, routes: routes)
            _ = try normal.encode(state)
            #expect(calls.count == 1)
            let limited = try RouterGraphSnapshotCodec(schemaID: "metadata.control", schemaVersion: 1, routes: routes, limits: limits)
            #expect(throws: failure) { try limited.encode(state) }
            #expect(calls.count == 1)
        }
    }

    @Test("Resource admission does not invoke application Route hashing or equality")
    func noApplicationCallbacks() throws {
        let calls = Calls()
        let route = ObservedRoute(calls: calls)
        let draft = RouterStateDraft(root: RouterNode<ObservedRoute>.stack(path: [route, route]))
        _ = try draft.build()
        try RouterResourceBudget.provisional.validate(root: draft.root)
        #expect(calls.count == 0)
    }

    @Test("Checked accounting rejects overflow even under an Int.max cap")
    func overflowIsFailClosed() throws {
        #expect(try RouterResourceBudget.addingResourceCount(.max - 1, 1, maximum: .max, resource: "test") == .max)
        #expect(try RouterResourceBudget.addingResourceCount(.max, 0, maximum: .max, resource: "test") == .max)
        expectLimit("test", actual: .max, maximum: .max) {
            _ = try RouterResourceBudget.addingResourceCount(.max, 1, maximum: .max, resource: "test")
        }
        expectLimit("test", actual: 4, maximum: 3) {
            _ = try RouterResourceBudget.addingResourceCount(2, 2, maximum: 3, resource: "test")
        }
        expectLimit("test", actual: .max, maximum: 3) {
            _ = try RouterResourceBudget.addingResourceCount(2, -1, maximum: 3, resource: "test")
        }
    }

    @Test("Execution limits preserve invalid input and support explicit unlimited choices")
    func executionDefaultsAndOptOut() throws {
        let standard = RouterResourceBudget.provisional
        #expect(standard.maximumPendingRequests == 256)
        #expect(standard.maximumDeferrals == 64)
        #expect(standard.maximumActivePolicyOperations == 64)
        #expect(standard.maximumActiveRestorationOperations == 8)
        #expect(standard.policyTimeout == .seconds(30))
        #expect(standard.deferralLifetime == .seconds(900))
        #expect(standard.durablePendingLifetime == .seconds(86_400))
        let blocked = RouterResourceBudget(
            maximumPendingRequests: -1, maximumDeferrals: -1,
            maximumActivePolicyOperations: -1, maximumActiveRestorationOperations: -1,
            policyTimeout: .seconds(-1), deferralLifetime: .seconds(-1), durablePendingLifetime: .seconds(-1),
            maximumJSONWorkUnits: -1, maximumJSONKeyDecodes: -1
        )
        #expect(blocked.maximumPendingRequests == -1 && blocked.maximumDeferrals == -1)
        #expect(blocked.maximumActivePolicyOperations == -1 && blocked.maximumActiveRestorationOperations == -1)
        #expect(blocked.policyTimeout == .seconds(-1) && blocked.deferralLifetime == .seconds(-1))
        #expect(blocked.maximumJSONWorkUnits == -1 && blocked.maximumJSONKeyDecodes == -1)
        #expect(throws: RouterResourceLimitFailure(
            code: .invalidConfiguration, resource: "configuration.maximumPendingRequests",
            actual: -1, maximum: .max, minimum: 0
        )) { try blocked.validate(RouterState<R>.rootStack) }
        let unlimited = RouterResourceBudget.unlimited
        #expect(unlimited.policyTimeout == nil && unlimited.deferralLifetime == nil && unlimited.durablePendingLifetime == nil)
        #expect(unlimited.maximumActivePolicyOperations == nil && unlimited.maximumActiveRestorationOperations == nil)
        #expect(unlimited.maximumPendingRequests == .max && unlimited.maximumDeferrals == .max)
        #expect(unlimited.maximumJSONWorkUnits == .max && unlimited.maximumJSONKeyDecodes == .max)
        try unlimited.validate(.rootStack(path: [R.home]))
    }

    @Test("All raw invalid budget fields reject before state admission")
    func invalidBudgetConfiguration() throws {
        let inputs: [(String, RouterResourceBudget)] = [
            ("maximumPendingRequests", .init(maximumPendingRequests: -1)),
            ("maximumDeferrals", .init(maximumDeferrals: -1)),
            ("maximumActivePolicyOperations", .init(maximumActivePolicyOperations: -1)),
            ("maximumActiveRestorationOperations", .init(maximumActiveRestorationOperations: -1)),
            ("maximumJSONWorkUnits", .init(maximumJSONWorkUnits: -1)),
            ("maximumJSONKeyDecodes", .init(maximumJSONKeyDecodes: -1)),
            ("legacyJSONDepth", .init(legacyJSONDepth: 0)),
            ("maximumScenarioSteps", .init(maximumScenarioSteps: 0)),
            ("maximumInspectorEntries", .init(maximumInspectorEntries: 0)),
            ("maximumRecordedInspectorEntries", .init(maximumRecordedInspectorEntries: 0)),
            ("maximumInspectorExportBytes", .init(maximumInspectorExportBytes: 0)),
            ("policyTimeout.seconds", .init(policyTimeout: .seconds(-1))),
            ("deferralLifetime.attoseconds", .init(deferralLifetime: .nanoseconds(-1))),
            ("durablePendingLifetime.seconds", .init(durablePendingLifetime: .seconds(-1))),
            ("scenarioImport.maximumTokens", .init(scenarioImport: .init(maximumEncodedBytes: 1, maximumDepth: 1, maximumTokens: 0))),
            ("inspectorImport.maximumDepth", .init(inspectorImport: .init(maximumEncodedBytes: 1, maximumDepth: 0, maximumTokens: 1))),
        ]
        for (field, budget) in inputs {
            do {
                try budget.validate(RouterState<R>.rootStack)
                Issue.record("Expected invalid configuration: \(field)")
            } catch {
                let failure = error
                #expect(failure.code == .invalidConfiguration)
                #expect(failure.resource == "configuration." + field)
                #expect(failure.actual < (failure.minimum ?? 0))
            }
        }
        let zero = RouterResourceBudget(
            maximumPendingRequests: 0, maximumDeferrals: 0,
            maximumActivePolicyOperations: 0, maximumActiveRestorationOperations: 0,
            policyTimeout: .zero, deferralLifetime: .zero, durablePendingLifetime: .zero,
            maximumJSONWorkUnits: 0, maximumJSONKeyDecodes: 0
        )
        try zero.validateConfiguration()
        try zero.validate(RouterState<R>.rootStack)
    }

    @Test("JSON import budgets reject invalid raw values without expansion")
    func rawJSONBudgetConfiguration() throws {
        let budget = RouterJSONImportBudget(maximumEncodedBytes: -1, maximumDepth: 0, maximumTokens: 0)
        #expect(budget.maximumEncodedBytes == -1)
        #expect(budget.maximumDepth == 0)
        #expect(budget.maximumTokens == 0)
        #expect(throws: RouterResourceLimitFailure(
            code: .invalidConfiguration, resource: "configuration.maximumEncodedBytes",
            actual: -1, maximum: .max, minimum: 1
        )) { try budget.validateConfiguration() }
        try RouterJSONImportBudget.unlimited.validateConfiguration()
    }

    @Test("Future resource codes round-trip and the description contains no detail payload")
    func extensibleFailure() throws {
        let failure = RouterResourceLimitFailure(code: .init(rawValue: "future.limit"), resource: "private-application-name", actual: .max, maximum: 1)
        #expect(failure.description == "future.limit")
        #expect(try JSONDecoder().decode(RouterResourceLimitFailure.self, from: JSONEncoder().encode(failure)) == failure)
    }
}
