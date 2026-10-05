import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

@Suite("Package-only explicit host node-shape groundwork")
struct RouterHostShapeContractTests {
    private enum R: String, Route { case home, detail }
    private typealias Shape = RouterHostShapeContract
    private typealias Branch = RouterHostShapeBranch
    private typealias Failure = RouterHostShapeFailure

    private func tabs(_ branches: [RouterBranch<R>], selection: RouterScopeID? = "home") throws -> RouterNode<R> {
        .container(try .init(style: .tabs, selection: selection, branches: branches))
    }

    private func declaredTabs(_ extras: RouterHostExtraBranches = .reject) -> Shape {
        .tabs(branches: [Branch("home", shape: .stack), Branch("settings", shape: .stack)], extras: extras)
    }

    private func standardTabs() throws -> RouterNode<R> {
        try tabs([.init(id: "home"), .init(id: "settings")])
    }

    private func check(
        _ shape: Shape, _ node: RouterNode<R>, scope: RouterScopePath = .root,
        budget: RouterResourceBudget = .provisional
    ) throws {
        try shape.validate(.init(root: node), at: scope, resourceBudget: budget)
    }

    private func expectFailure(
        _ code: Failure.Code, scope: RouterScopePath = .root, detail: Failure.Detail? = nil,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("Expected a host-shape failure")
        } catch let failure as Failure {
            #expect(failure.code == code)
            #expect(failure.scope == scope)
            if let detail { #expect(failure.detail == detail) }
            #expect(failure.description == code.rawValue)
        } catch {
            Issue.record("Expected a structured host-shape failure, received \(type(of: error))")
        }
    }

    @Test("Stack/tabs/custom mismatches use the actual node, not scope existence")
    func actualNodeKinds() throws {
        let actualTabs = try standardTabs()
        try check(.stack, .stack(path: [.home]))
        try check(declaredTabs(), actualTabs)
        expectFailure(.kindMismatch, detail: .nodeKind) { try check(.stack, actualTabs) }
        expectFailure(.kindMismatch, detail: .nodeKind) { try check(declaredTabs(), .stack()) }
        let custom = RouterNode<R>.container(try .init(style: .custom("workspace"), branches: []))
        expectFailure(.kindMismatch, detail: .nodeKind) { try check(declaredTabs(), custom) }
        try check(.custom(declarationID: "workspace", branches: [], extras: .reject), custom)
        expectFailure(.kindMismatch, detail: .customDeclaration) {
            try check(.custom(declarationID: "other", branches: [], extras: .reject), custom)
        }
    }

    @Test("Every declared inactive branch receives its explicit recursive check")
    func invalidInactiveBranch() throws {
        let child = try tabs([.init(id: "home")])
        let node = try tabs([.init(id: "home"), .init(id: "settings", node: child)])
        expectFailure(.kindMismatch, scope: ["settings"], detail: .nodeKind) {
            try check(declaredTabs(), node)
        }
        let recursive = Shape.tabs(branches: [
            Branch("home", shape: .stack),
            Branch("settings", shape: .tabs(branches: [Branch("home", shape: .stack)], extras: .reject)),
        ], extras: .reject)
        try check(recursive, node)
        try check(recursive, try tabs([.init(id: "home", node: .stack(path: [.detail])), .init(id: "settings", node: child)]))
    }

    @Test("Extra restored tabs require explicit preservation and remain unchanged")
    func restoredDormantOrphanControl() throws {
        let oldExtra = RouterBranch<R>(id: "legacy", node: .stack(path: [.home, .detail]))
        let node = try tabs([.init(id: "home"), oldExtra, .init(id: "settings")])
        let input = RouterStateDraft<R>(root: node)
        expectFailure(.extraBranch, scope: ["legacy"], detail: .undeclaredBranch) {
            try declaredTabs().validate(input, at: .root, resourceBudget: .provisional)
        }
        try declaredTabs(.preserveDormant).validate(input, at: .root, resourceBudget: .provisional)
        #expect(input.root == node)
        if case .container(let preserved) = input.root {
            #expect(preserved.branches.count == 3)
            #expect(preserved.branches[1] == oldExtra)
        } else { Issue.record("Preserved input must remain a container") }
    }

    @Test("A preserved extra can never be the rendered selection")
    func dormantSelectionRejected() throws {
        let branches: [RouterBranch<R>] = [.init(id: "home"), .init(id: "settings"), .init(id: "legacy")]
        expectFailure(.selectionNotRendered, detail: .selectedBranchUndeclared) {
            try check(declaredTabs(.preserveDormant), try tabs(branches, selection: "legacy"))
        }
        try check(declaredTabs(.preserveDormant), try tabs(branches, selection: "settings"))
    }

    @Test("Declared missing branches and order mismatches reject independently")
    func missingBranchAndOrder() throws {
        expectFailure(.missingBranch, scope: ["settings"], detail: .declaredBranchUnavailable) {
            try check(declaredTabs(), try tabs([.init(id: "home")]))
        }
        expectFailure(.branchOrderMismatch, detail: .orderedBranches) {
            try check(declaredTabs(.preserveDormant), try tabs([.init(id: "settings"), .init(id: "legacy"), .init(id: "home")]))
        }
        try check(declaredTabs(), try standardTabs())
    }

    @Test("Custom declarations preserve optional selection and may have no branches")
    func customOptionalSelection() throws {
        let shape = Shape.custom(declarationID: "workspace", branches: [Branch("home", shape: .stack)], extras: .preserveDormant)
        let branches: [RouterBranch<R>] = [.init(id: "home"), .init(id: "legacy")]
        try check(shape, .container(try .init(style: .custom("workspace"), selection: nil, branches: branches)))
        try check(shape, .container(try .init(style: .custom("workspace"), selection: "home", branches: branches)))
        expectFailure(.selectionNotRendered, detail: .selectedBranchUndeclared) {
            try check(shape, .container(try .init(style: .custom("workspace"), selection: "legacy", branches: branches)))
        }
        try check(.custom(declarationID: "empty", branches: [], extras: .reject), .container(try .init(style: .custom("empty"), branches: [])))
    }

    @Test("Two-column roles match exactly; stored branch order does not change column semantics")
    func exactTwoColumnMapping() throws {
        let shape = Shape.splitTwo(sidebar: Branch("left", shape: .stack), detail: Branch("right", shape: .stack))
        let branches: [RouterBranch<R>] = [.init(id: "right"), .init(id: "left")]
        let valid = RouterNode<R>.container(try .init(style: .split, branches: branches, split: try .init(sidebar: "left", detail: "right")))
        try check(shape, valid)
        let swapped = RouterNode<R>.container(try .init(style: .split, branches: branches, split: try .init(sidebar: "right", detail: "left")))
        expectFailure(.splitMappingMismatch, detail: .splitColumns) { try check(shape, swapped) }
        expectFailure(.kindMismatch, detail: .nodeKind) { try check(declaredTabs(), valid) }
    }

    @Test("Two and three-column declarations cannot silently adapt or swap roles")
    func exactThreeColumnMapping() throws {
        let two = Shape.splitTwo(sidebar: Branch("left", shape: .stack), detail: Branch("right", shape: .stack))
        let three = Shape.splitThree(sidebar: Branch("left", shape: .stack), content: Branch("middle", shape: .stack), detail: Branch("right", shape: .stack))
        let threeNode = RouterNode<R>.container(try .init(style: .split, branches: [.init(id: "right"), .init(id: "left"), .init(id: "middle")], split: try .init(sidebar: "left", content: "middle", detail: "right")))
        let twoNode = RouterNode<R>.container(try .init(style: .split, branches: [.init(id: "left"), .init(id: "right")], split: try .init(sidebar: "left", detail: "right")))
        try check(three, threeNode)
        expectFailure(.splitMappingMismatch, detail: .splitColumns) { try check(two, threeNode) }
        expectFailure(.splitMappingMismatch, detail: .splitColumns) { try check(three, twoNode) }
        let wrongRoles = Shape.splitThree(sidebar: Branch("left", shape: .stack), content: Branch("right", shape: .stack), detail: Branch("middle", shape: .stack))
        expectFailure(.splitMappingMismatch, detail: .splitColumns) { try check(wrongRoles, threeNode) }
    }

    @Test("Inactive split children are validated even when the detail is the selection")
    func splitChildMismatch() throws {
        let node = RouterNode<R>.container(try .init(style: .split, selection: "right", branches: [.init(id: "left", node: standardTabs()), .init(id: "right")], split: try .init(sidebar: "left", detail: "right")))
        expectFailure(.kindMismatch, scope: ["left"], detail: .nodeKind) {
            try check(.splitTwo(sidebar: Branch("left", shape: .stack), detail: Branch("right", shape: .stack)), node)
        }
        try check(.splitTwo(sidebar: Branch("left", shape: declaredTabs()), detail: Branch("right", shape: .stack)), node)
    }

    @Test("Malformed declarations are rejected, including inactive recursive children")
    func malformedDeclarations() throws {
        let node = try standardTabs()
        expectFailure(.invalidDeclaration, detail: .duplicateBranch) {
            try check(.tabs(branches: [Branch("home", shape: .stack), Branch("home", shape: .stack)], extras: .reject), node)
        }
        expectFailure(.invalidDeclaration, detail: .emptyIdentifier) {
            try check(.tabs(branches: [Branch("", shape: .stack)], extras: .reject), node)
        }
        expectFailure(.invalidDeclaration, detail: .emptyTabs) {
            try check(.tabs(branches: [], extras: .reject), node)
        }
        expectFailure(.invalidDeclaration, detail: .emptyIdentifier) {
            try check(.custom(declarationID: "", branches: [], extras: .reject), node)
        }
        expectFailure(.invalidDeclaration, detail: .duplicateBranch) {
            try check(.splitThree(sidebar: Branch("x", shape: .stack), content: Branch("y", shape: .stack), detail: Branch("x", shape: .stack)), node)
        }
        let badChild = Shape.tabs(branches: [Branch("x", shape: .stack), Branch("x", shape: .stack)], extras: .reject)
        expectFailure(.invalidDeclaration, scope: ["settings"], detail: .duplicateBranch) {
            try check(.tabs(branches: [Branch("home", shape: .stack), Branch("settings", shape: badChild)], extras: .reject), node)
        }
    }

    @Test("Malformed state IDs, selections and split mappings reject before matching")
    func malformedState() throws {
        guard case .container(var container) = try standardTabs() else { return }
        container.branches.append(container.branches[0])
        expectFailure(.invalidState, detail: .stateStructure) { try check(declaredTabs(.preserveDormant), .container(container)) }
        container.branches.removeLast()
        container.branches[1].id = ""
        expectFailure(.invalidState, detail: .stateStructure) { try check(declaredTabs(.preserveDormant), .container(container)) }
        container.branches[1].id = "settings"
        container.selection = "missing"
        expectFailure(.invalidState, detail: .stateStructure) { try check(declaredTabs(), .container(container)) }
        container.selection = "home"
        container.style = .split
        container.split = try .init(sidebar: "home", detail: "settings")
        container.split?.detail = "missing"
        expectFailure(.invalidState, detail: .stateStructure) { try check(.stack, .container(container)) }
    }

    @Test("Invalid dormant extra subtrees are never skipped")
    func invalidPreservedSubtree() throws {
        guard case .container(var invalid) = try standardTabs() else { return }
        invalid.selection = "missing"
        let node = try tabs([.init(id: "home"), .init(id: "settings"), .init(id: "legacy", node: .container(invalid))])
        expectFailure(.invalidState, detail: .stateStructure) { try check(declaredTabs(.preserveDormant), node) }
    }

    @Test("Typed branch, presentation, window and immersive paths resolve actual nodes")
    func typedPathsAndSiblingControls() throws {
        let id = UUID()
        let presentation = try RouterPresentation<R>(id: id, route: .home, style: .sheet, node: standardTabs())
        let windowID = UUID()
        let input = RouterStateDraft<R>(
            root: try tabs([.init(id: "home", node: .stack(presentation: presentation)), .init(id: "settings")]),
            windows: [.init(id: windowID, route: .home, node: try standardTabs())],
            immersiveSpace: .init(id: "world", route: .home, node: try standardTabs())
        )
        let path = RouterScopePath(["home"]).appendingPresentation(id)
        try declaredTabs().validate(input, at: path, resourceBudget: .provisional)
        try declaredTabs().validate(input, at: .window(windowID), resourceBudget: .provisional)
        try declaredTabs().validate(input, at: .immersiveSpace("world"), resourceBudget: .provisional)
        try Shape.stack.validate(input, at: ["settings"], resourceBudget: .provisional)
        expectFailure(.kindMismatch, scope: path, detail: .nodeKind) {
            try Shape.stack.validate(input, at: path, resourceBudget: .provisional)
        }
        let missing = RouterScopePath(["home"]).appendingPresentation(UUID())
        expectFailure(.missingScope, scope: missing, detail: .nodeUnavailable) {
            try Shape.stack.validate(input, at: missing, resourceBudget: .provisional)
        }
    }

    @Test("A valid requested scope does not hide invalid unrelated scenes")
    func wholeInputValidation() throws {
        guard case .container(var invalid) = try standardTabs() else { return }
        invalid.selection = "missing"
        let input = RouterStateDraft<R>(root: .stack(), windows: [.init(route: .home, node: .container(invalid))])
        expectFailure(.invalidState, detail: .stateStructure) {
            try Shape.stack.validate(input, at: .root, resourceBudget: .provisional)
        }
    }

    @Test("A stack shape does not claim unprovided presentation renderer contracts")
    func nodeOnlyBoundaryIsExplicit() throws {
        let input = try RouterNode<R>.stack(presentation: .init(route: .detail, style: .sheet, node: standardTabs()))
        try check(.stack, input)
    }

    @Test("Empty paths reject; arbitrary nonempty stable IDs are not parsed as path strings")
    func scopeSyntax() throws {
        expectFailure(.invalidScope, scope: [""], detail: .emptyIdentifier) {
            try check(.stack, .stack(), scope: [""])
        }
        let id: RouterScopeID = "literal/slash/presentation[still-a-branch]"
        let node = try tabs([.init(id: id)], selection: id)
        try check(.stack, node, scope: .init([.branch(id)]))
    }

    @Test("Whole-state resource checks precede malformed declarations and include dormant nodes")
    func inputResourceAdmission() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumNodes: 3))
        let node = try tabs([.init(id: "home"), .init(id: "settings"), .init(id: "legacy")])
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "state.nodes", actual: 4, maximum: 3))) {
            try check(declaredTabs(.preserveDormant), node, budget: budget)
        }
        try check(declaredTabs(), try standardTabs(), budget: budget)
    }

    @Test("Descriptor aggregate node count rejects before duplicate ID hashing")
    func declarationNodeBudget() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumNodes: 3))
        let excess = Shape.tabs(branches: Array(repeating: Branch("same", shape: .stack), count: 3), extras: .reject)
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "hostShape.nodes", actual: 4, maximum: 3))) {
            try check(excess, .stack(), budget: budget)
        }
        try check(declaredTabs(), try standardTabs(), budget: budget)
    }

    @Test("Descriptor depth is bounded iteratively, including its requested path")
    func declarationDepthBudget() throws {
        var shape = Shape.stack
        for _ in 0..<512 { shape = .custom(declarationID: "c", branches: [Branch("b", shape: shape)], extras: .reject) }
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "hostShape.depth", actual: 33, maximum: 32))) {
            try check(shape, .stack())
        }
        let path = RouterScopePath(Array(repeating: .branch("b"), count: 32))
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "hostShape.depth", actual: 33, maximum: 32))) {
            try check(.stack, .stack(), scope: path)
        }
        let shallowBudget = RouterResourceBudget(snapshot: try .init(maximumGraphDepth: 2))
        try check(declaredTabs(), try standardTabs(), budget: shallowBudget)
    }

    @Test("Descriptor metadata counts every occurrence as UTF-8 and stops at the first excess byte")
    func declarationMetadataBudget() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 5))
        let oversized = Shape.custom(declarationID: "c", branches: [Branch("ééé", shape: .stack)], extras: .reject)
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "hostShape.metadataBytes", actual: 6, maximum: 5))) {
            try check(oversized, .stack(), budget: budget)
        }
        let repeated = Shape.tabs(branches: [Branch("aaa", shape: .stack), Branch("aaa", shape: .stack)], extras: .reject)
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "hostShape.metadataBytes", actual: 6, maximum: 5))) {
            try check(repeated, .stack(), budget: budget)
        }
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "hostShape.metadataBytes", actual: 6, maximum: 5))) {
            try check(.stack, .stack(), scope: ["aaaaaa"], budget: budget)
        }
    }

    @Test("Exact descriptor depth and metadata boundaries admit without an opt-out")
    func exactDeclarationBoundaries() throws {
        var shape = Shape.stack
        var node = RouterNode<R>.stack()
        for _ in 1..<32 {
            shape = .custom(declarationID: "c", branches: [Branch("b", shape: shape)], extras: .reject)
            node = .container(try .init(style: .custom("c"), branches: [.init(id: "b", node: node)]))
        }
        try check(shape, node)
        let exact = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 5))
        try check(.custom(declarationID: "abcde", branches: [], extras: .reject),
                  .container(try .init(style: .custom("abcde"), branches: [])), budget: exact)
    }

    @Test("A deep dormant branch and oversized unrelated scene remain subject to whole-input admission")
    func completeInputResources() throws {
        var child = RouterNode<R>.stack()
        for _ in 0..<40 {
            child = .container(try .init(style: .custom("c"), branches: [.init(id: "b", node: child)]))
        }
        let node = try tabs([.init(id: "home"), .init(id: "settings"), .init(id: "legacy", node: child)])
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "state.graphDepth", actual: 33, maximum: 32))) {
            try check(declaredTabs(.preserveDormant), node)
        }
        let input = RouterStateDraft<R>(root: .stack(), windows: [.init(route: .home, node: .stack(path: [.home, .detail]))])
        let budget = RouterResourceBudget(snapshot: try .init(maximumStackPath: 1))
        expectFailure(.resourceLimit, detail: .resource(.init(resource: "state.stackPath", actual: 2, maximum: 1))) {
            try Shape.stack.validate(input, at: .root, resourceBudget: budget)
        }
    }

    @Test("Nonfinite presentation options in dormant branches remain structural failures")
    func invalidDormantPresentationOptions() throws {
        let bad = RouterNode<R>.stack(presentation: .init(route: .home, style: .sheet, options: .init(cornerRadius: .nan)))
        let node = try tabs([.init(id: "home"), .init(id: "settings"), .init(id: "legacy", node: bad)])
        expectFailure(.invalidState, detail: .stateStructure) { try check(declaredTabs(.preserveDormant), node) }
    }

    @Test("Invalid resource configuration is returned as a structured failure")
    func invalidBudget() {
        let budget = RouterResourceBudget(maximumPendingRequests: -1)
        expectFailure(.resourceLimit) { try check(.stack, .stack(), budget: budget) }
    }

    private final class Calls: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func hit() { value.withLock { $0 += 1 } }
    }

    private struct ObservedRoute: Route {
        let calls: Calls
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.calls.hit(); return true }
        func hash(into hasher: inout Hasher) { calls.hit() }
    }

    @Test("Shape validation never compares, hashes or describes opaque routes")
    func payloadFree() throws {
        let calls = Calls()
        let route = ObservedRoute(calls: calls)
        let input = RouterStateDraft<ObservedRoute>(root: .stack(path: [route], presentation: .init(route: route, style: .sheet)))
        try Shape.stack.validate(input, at: .root, resourceBudget: .provisional)
        #expect(calls.count == 0)
    }
}
