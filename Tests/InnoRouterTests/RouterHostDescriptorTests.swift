import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

@Suite("Frozen public host descriptors and whole-state catalog admission")
struct RouterHostDescriptorTests {
    private enum R: String, Route { case home, compose, settings, window, world, unknown }
    private typealias Shape = RouterHostShape
    private typealias Descriptor = RouterHostDescriptor<R>
    private typealias Failure = RouterHostValidationFailure

    private var tabsShape: Shape {
        .tabs(branches: [.init("home", shape: .stack), .init("settings", shape: .stack)], extras: .reject)
    }

    private func tabs() throws -> RouterNode<R> {
        .container(try .init(style: .tabs, selection: "home", branches: [.init(id: "home"), .init(id: "settings")]))
    }

    private func catalog(_ id: String, shape: Shape, route: R) -> RouterHostCatalog<R> {
        .init(entries: [.init(id, shape: shape)], declaration: { $0 == route ? id : nil })
    }

    private func expectFailure(
        _ code: Failure.Code, scope: RouterScopePath = .root,
        operation: () throws -> Void
    ) {
        do { try operation(); Issue.record("Expected a structured host failure") }
        catch let failure as Failure {
            #expect(failure.code == code)
            #expect(failure.scope == scope)
            #expect(failure.description == code.rawValue)
        } catch { Issue.record("Expected host validation failure; received \(type(of: error))") }
    }

    @Test("The default presentation catalog is an explicit all-stack contract")
    func defaultPresentationContract() throws {
        let id = UUID()
        let descriptor = Descriptor(root: .stack)
        let valid = RouterStateDraft<R>(root: .stack(presentation: .init(id: id, route: .compose, style: .sheet)))
        try descriptor.validate(valid)
        #expect(try descriptor.shape(at: .root.appendingPresentation(id), in: valid) == .stack)
        let invalid = try RouterStateDraft<R>(root: .stack(presentation: .init(id: id, route: .compose, style: .sheet, node: tabs())))
        expectFailure(.kindMismatch, scope: .root.appendingPresentation(id)) { try descriptor.validate(invalid) }
    }

    @Test("Changing a candidate never changes a frozen route-to-shape declaration")
    func candidateCannotInferContract() throws {
        let id = UUID()
        let descriptor = Descriptor(root: .stack, presentations: catalog("compose", shape: tabsShape, route: .compose))
        let correct = try RouterStateDraft<R>(root: .stack(presentation: .init(id: id, route: .compose, style: .sheet, node: tabs())))
        try descriptor.validate(correct)
        let wrong = RouterStateDraft<R>(root: .stack(presentation: .init(id: id, route: .compose, style: .sheet)))
        expectFailure(.kindMismatch, scope: .root.appendingPresentation(id)) { try descriptor.validate(wrong) }
    }

    @Test("Unknown presentation routes fail closed even with a structurally valid child")
    func unknownPresentation() throws {
        let id = UUID()
        let descriptor = Descriptor(root: .stack, presentations: catalog("compose", shape: .stack, route: .compose))
        let unknown = RouterStateDraft<R>(root: .stack(presentation: .init(id: id, route: .unknown, style: .sheet)))
        expectFailure(.unknownDeclaration, scope: .root.appendingPresentation(id)) { try descriptor.validate(unknown) }
        expectFailure(.unknownDeclaration, scope: .root.appendingPresentation(id)) {
            try Descriptor(root: .stack, presentations: .none).validate(unknown)
        }
    }

    @Test("Every nested presentation resolves its own route contract")
    func nestedPresentationContracts() throws {
        let outer = UUID(), inner = UUID()
        let innerNode = RouterNode<R>.stack(presentation: .init(id: inner, route: .settings, style: .popover))
        let child = RouterNode<R>.container(try .init(style: .tabs, selection: "home", branches: [
            .init(id: "home"), .init(id: "settings", node: innerNode),
        ]))
        let descriptor = Descriptor(root: .stack, presentations: .init(entries: [
            .init("compose", shape: tabsShape), .init("settings", shape: .stack),
        ], declaration: { route in
            switch route { case .compose: "compose"; case .settings: "settings"; default: nil }
        }))
        let draft = RouterStateDraft<R>(root: .stack(presentation: .init(id: outer, route: .compose, style: .sheet, node: child)))
        try descriptor.validate(draft)
        let scope = RouterScopePath.root.appendingPresentation(outer).appending("settings").appendingPresentation(inner)
        #expect(try descriptor.shape(at: scope, in: draft) == .stack)
        let restricted = Descriptor(root: .stack, presentations: catalog("compose", shape: tabsShape, route: .compose))
        expectFailure(.unknownDeclaration, scope: scope) { try restricted.validate(draft) }
    }

    @Test("Window declarations validate every instance without deriving its shape")
    func windows() throws {
        let first = UUID(), second = UUID()
        let descriptor = Descriptor(root: .stack, windows: catalog("document", shape: tabsShape, route: .window))
        let valid = try RouterStateDraft<R>(root: .stack(), windows: [
            .init(id: first, route: .window, node: tabs()), .init(id: second, route: .window, node: tabs()),
        ])
        try descriptor.validate(valid)
        #expect(try descriptor.shape(at: .window(second), in: valid) == tabsShape)
        var wrong = valid
        wrong.windows[1].node = .stack()
        expectFailure(.kindMismatch, scope: .window(second)) { try descriptor.validate(wrong) }
        expectFailure(.unknownDeclaration, scope: .window(first)) { try Descriptor(root: .stack).validate(valid) }
    }

    @Test("Scene surfaces cannot borrow another surface's catalog")
    func surfaceSeparation() throws {
        let id = UUID()
        let descriptor = Descriptor(root: .stack, presentations: catalog("window", shape: .stack, route: .window))
        let draft = RouterStateDraft<R>(root: .stack(), windows: [.init(id: id, route: .window)])
        expectFailure(.unknownDeclaration, scope: .window(id)) { try descriptor.validate(draft) }
    }

    @Test("Immersive declarations require the stable scene identifier and shape")
    func immersive() throws {
        let descriptor = Descriptor(root: .stack, immersiveSpaces: catalog("world", shape: tabsShape, route: .world))
        let valid = try RouterStateDraft<R>(root: .stack(), immersiveSpace: .init(id: "world", route: .world, node: tabs()))
        try descriptor.validate(valid)
        #expect(try descriptor.shape(at: .immersiveSpace("world"), in: valid) == tabsShape)
        var wrongID = valid
        wrongID.immersiveSpace?.id = "other"
        expectFailure(.sceneIdentifierMismatch, scope: .immersiveSpace("other")) { try descriptor.validate(wrongID) }
        var wrongShape = valid
        wrongShape.immersiveSpace?.node = .stack()
        expectFailure(.kindMismatch, scope: .immersiveSpace("world")) { try descriptor.validate(wrongShape) }
    }

    @Test("Catalog declarations are checked even when no route activates them")
    func unusedCatalogValidation() {
        let duplicate = RouterHostCatalog<R>(entries: [.init("a", shape: .stack), .init("a", shape: .stack)], declaration: { _ in nil })
        expectFailure(.duplicateDeclaration) { try Descriptor(root: .stack, windows: duplicate).validate(.rootStack) }
        let empty = RouterHostCatalog<R>(entries: [.init("", shape: .stack)], declaration: { _ in nil })
        expectFailure(.invalidDeclaration) { try Descriptor(root: .stack, windows: empty).validate(.rootStack) }
        let malformed = catalog("unused", shape: .tabs(branches: [], extras: .reject), route: .unknown)
        expectFailure(.invalidDeclaration) { try Descriptor(root: .stack, windows: malformed).validate(.rootStack) }
    }

    @Test("Unknown resolver output cannot materialize an undeclared host")
    func unknownResolverOutput() {
        let id = UUID()
        let catalog = RouterHostCatalog<R>(entries: [.init("known", shape: .stack)], declaration: { _ in "unknown" })
        let draft = RouterStateDraft<R>(root: .stack(), windows: [.init(id: id, route: .window)])
        expectFailure(.unknownDeclaration, scope: .window(id)) {
            try Descriptor(root: .stack, windows: catalog).validate(draft)
        }
    }

    @Test("Renderer checking compares the frozen declaration, including orphan policy")
    func rendererValidation() throws {
        let state = try RouterState<R>(root: tabs())
        let descriptor = Descriptor(root: tabsShape)
        try descriptor.validateRenderer(tabsShape, at: .root, in: state)
        try descriptor.validateRenderer(.stack, at: ["home"], in: state)
        let permissive = Shape.tabs(branches: [.init("home", shape: .stack), .init("settings", shape: .stack)], extras: .preserveDormant)
        expectFailure(.rendererMismatch) { try descriptor.validateRenderer(permissive, at: .root, in: state) }
        expectFailure(.rendererMismatch) { try descriptor.validateRenderer(.stack, at: .root, in: state) }
        expectFailure(.missingScope, scope: ["absent"]) {
            try descriptor.validateRenderer(.stack, at: ["absent"], in: state)
        }
    }

    @Test("Renderer checking rejects the invalid candidate before comparing renderers")
    func rendererInvalidCandidate() throws {
        let descriptor = Descriptor(root: tabsShape)
        expectFailure(.kindMismatch) {
            try descriptor.validateRenderer(.stack, at: .root, in: RouterState<R>.rootStack)
        }
    }

    @Test("Dormant branches are preserved intact but do not become renderable scopes")
    func dormantScopeIsNotRenderer() throws {
        let dormantID = UUID()
        let shape = Shape.tabs(branches: [.init("home", shape: .stack)], extras: .preserveDormant)
        let legacy = RouterNode<R>.stack(path: [.settings], presentation: .init(id: dormantID, route: .compose, style: .sheet))
        let node = RouterNode<R>.container(try .init(style: .tabs, selection: "home", branches: [
            .init(id: "home"), .init(id: "legacy", node: legacy),
        ]))
        let input = RouterStateDraft<R>(root: node)
        let descriptor = Descriptor(root: shape)
        try descriptor.validate(input)
        #expect(input.root == node)
        expectFailure(.missingScope, scope: ["legacy"]) { _ = try descriptor.shape(at: ["legacy"], in: input) }
        let hiddenPresentation = RouterScopePath(["legacy"]).appendingPresentation(dormantID)
        expectFailure(.missingScope, scope: hiddenPresentation) { _ = try descriptor.shape(at: hiddenPresentation, in: input) }
        expectFailure(.unknownDeclaration, scope: hiddenPresentation) {
            try Descriptor(root: shape, presentations: .none).validate(input)
        }
    }

    @Test("Descriptor node counts accumulate across all otherwise small catalog entries")
    func cumulativeDescriptorNodes() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumNodes: 3))
        let entries: [RouterHostCatalogEntry<R>] = [.init("a", shape: .stack), .init("b", shape: .stack)]
        let catalog = RouterHostCatalog<R>(entries: entries, declaration: { _ in "a" })
        try Descriptor(root: .stack, presentations: .none, windows: catalog).validate(.rootStack, resourceBudget: budget)
        let over = Descriptor(root: .stack, windows: catalog)
        expectFailure(.resourceLimit) { try over.validate(.rootStack, resourceBudget: budget) }
        do { try over.validate(.rootStack, resourceBudget: budget) }
        catch let failure { #expect(failure.resourceLimit?.resource == "hostShape.nodes"); #expect(failure.resourceLimit?.actual == 4) }
    }

    @Test("Descriptor metadata counts all repeated IDs across every catalog")
    func cumulativeMetadata() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 5))
        let a = catalog("aaa", shape: .stack, route: .home)
        expectFailure(.resourceLimit) {
            try Descriptor(root: .stack, presentations: a, windows: a).validate(.rootStack, resourceBudget: budget)
        }
        try Descriptor(root: .stack, presentations: .none, windows: catalog("ééa", shape: .stack, route: .home))
            .validate(.rootStack, resourceBudget: budget)
    }

    @Test("Oversized and deep unused declarations reject before application resolvers run")
    func descriptorAdmissionBeforeResolver() throws {
        let calls = Calls()
        var deep = Shape.stack
        for _ in 0..<64 { deep = .custom(declarationID: "c", branches: [.init("b", shape: deep)], extras: .reject) }
        let catalog = RouterHostCatalog<R>(entries: [.init("unused", shape: deep)], declaration: { _ in calls.hit(); return "unused" })
        expectFailure(.resourceLimit) {
            try Descriptor(root: .stack, windows: catalog).validate(RouterStateDraft<R>(root: .stack(), windows: [.init(route: .window)]))
        }
        #expect(calls.count == 0)
    }

    @Test("Whole-state admission precedes application resolver invocation")
    func stateAdmissionBeforeResolver() throws {
        let calls = Calls()
        let catalog = RouterHostCatalog<R>(entries: [.init("window", shape: .stack)], declaration: { _ in calls.hit(); return "window" })
        let descriptor = Descriptor(root: .stack, windows: catalog)
        let budget = RouterResourceBudget(snapshot: try .init(maximumStackPath: 1))
        let over = RouterStateDraft<R>(root: .stack(), windows: [.init(route: .window, node: .stack(path: [.home, .settings]))])
        expectFailure(.resourceLimit) { try descriptor.validate(over, resourceBudget: budget) }
        guard case .container(var invalid) = try tabs() else { return }
        invalid.selection = "missing"
        expectFailure(.invalidState) {
            try descriptor.validate(RouterStateDraft<R>(root: .stack(), windows: [.init(route: .window, node: .container(invalid))]))
        }
        #expect(calls.count == 0)
    }

    @Test("Resolver output has its own bounded repeated metadata admission")
    func resolverOutputBudget() throws {
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 8))
        let catalog = RouterHostCatalog<R>(entries: [.init("a", shape: .stack)], declaration: { _ in "secret-payload-not-a-key" })
        let descriptor = Descriptor(root: .stack, presentations: .none, windows: catalog)
        let draft = RouterStateDraft<R>(root: .stack(), windows: [.init(route: .window)])
        expectFailure(.resourceLimit) { try descriptor.validate(draft, resourceBudget: budget) }
        do { try descriptor.validate(draft, resourceBudget: budget) }
        catch let failure {
            #expect(!String(describing: failure).contains("secret"))
            #expect(!String(reflecting: failure).contains("secret"))
            #expect(failure.resourceLimit?.actual == 9)
        }
    }

    @Test("Invalid resource configuration returns a typed descriptor failure")
    func invalidBudget() {
        expectFailure(.resourceLimit) {
            try Descriptor(root: .stack).validate(.rootStack, resourceBudget: .init(maximumPendingRequests: -1))
        }
    }

    @Test("Renderer declarations and target paths receive independent bounded admission")
    func rendererAdmission() throws {
        let descriptor = Descriptor(root: .stack)
        let huge = Shape.custom(declarationID: String(repeating: "x", count: 50), branches: [], extras: .reject)
        let budget = RouterResourceBudget(snapshot: try .init(maximumPayloadBytes: 10))
        expectFailure(.resourceLimit) { try descriptor.validateRenderer(huge, at: .root, in: RouterState<R>.rootStack, resourceBudget: budget) }
        let scope = RouterScopePath([.branch(.init(String(repeating: "x", count: 50)))])
        expectFailure(.resourceLimit) { _ = try descriptor.shape(at: scope, in: RouterState<R>.rootStack, resourceBudget: budget) }
        expectFailure(.invalidScope, scope: [""]) { _ = try descriptor.shape(at: [""], in: RouterState<R>.rootStack) }
    }

    @Test("Failure codes remain extensible, hashable and payload-safe")
    func failureContract() {
        let unknown = Failure.Code(rawValue: "hostShape.future")
        let failure = Failure(code: unknown)
        #expect(failure.description == "hostShape.future")
        #expect(Set([failure, failure]).count == 1)
        let secret = Failure(code: .missingScope, scope: ["private-identifier"])
        #expect(!String(describing: secret).contains("private-identifier"))
        #expect(!String(reflecting: secret).contains("private-identifier"))
        #expect(RouterRejectionReason.hostContract(failure) == .hostContract(failure))
    }

    private final class Calls: Sendable {
        private let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func hit() { value.withLock { $0 += 1 } }
    }
    private struct Opaque: Route {
        let calls: Calls
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.calls.hit(); return true }
        func hash(into hasher: inout Hasher) { calls.hit() }
    }

    @Test("Descriptor matching never implicitly hashes or compares opaque routes")
    func opaquePayloads() throws {
        let calls = Calls()
        let route = Opaque(calls: calls)
        let draft = RouterStateDraft<Opaque>(root: .stack(path: [route], presentation: .init(route: route, style: .sheet)), windows: [.init(route: route)])
        try RouterHostDescriptor<Opaque>(root: .stack, windows: .stack).validate(draft)
        #expect(calls.count == 0)
    }
}
