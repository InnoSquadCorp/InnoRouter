import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

@Suite("Frozen host root meanings", .serialized)
struct RouterHostRootDeclarationTests {
    private enum R: String, Route { case home, settings, compose, window }
    private typealias Descriptor = RouterHostDescriptor<R>
    private typealias Root = RouterHostRootDeclaration<R>
    private typealias Failure = RouterHostValidationFailure

    private var shape: RouterHostShape {
        .tabs(branches: [.init("home", shape: .stack), .init("settings", shape: .stack)], extras: .reject)
    }

    private var roots: [Root] {
        [.init(path: ["home"], meaning: .route(.home)), .init(path: ["settings"], meaning: .route(.settings))]
    }

    private func state() throws -> RouterState<R> {
        try .init(root: .container(.init(
            style: .tabs, selection: "home", branches: [.init(id: "home"), .init(id: "settings")]
        )))
    }

    private func expectFailure(_ code: Failure.Code, operation: () throws -> Void) {
        do { try operation(); Issue.record("Expected a structured host failure") }
        catch let failure as Failure {
            #expect(failure.code == code)
            #expect(failure.description == code.rawValue)
            #expect(failure.debugDescription == code.rawValue)
        } catch { Issue.record("Expected host failure; received \(type(of: error))") }
    }

    @Test("Same branch IDs and shape cannot silently change native root routes")
    func exactRoutes() throws {
        let state = try state(), descriptor = Descriptor(root: shape, rootDeclarations: roots)
        try descriptor.validateRenderer(shape, rootDeclarations: roots, at: .root, in: state)
        let changed: [Root] = [
            .init(path: ["home"], meaning: .route(.compose)), .init(path: ["settings"], meaning: .route(.settings)),
        ]
        expectFailure(.rendererMismatch) {
            try descriptor.validateRenderer(shape, rootDeclarations: changed, at: .root, in: state)
        }
        // A newly supplied complete contract admits the changed meanings. Store
        // replacement, rather than this read-only operation, owns retirement.
        try Descriptor(root: shape, rootDeclarations: changed)
            .validateRenderer(shape, rootDeclarations: changed, at: .root, in: state)
    }

    @Test("Empty or extra root mappings never bypass the frozen contract")
    func requiredCompleteMapping() throws {
        let state = try state(), descriptor = Descriptor(root: shape, rootDeclarations: roots)
        expectFailure(.rendererMismatch) { try descriptor.validateRenderer(shape, at: .root, in: state) }
        expectFailure(.rendererMismatch) {
            try descriptor.validateRenderer(shape, rootDeclarations: Array(roots.prefix(1)), at: .root, in: state)
        }
        expectFailure(.rendererMismatch) {
            try Descriptor(root: shape).validateRenderer(shape, rootDeclarations: roots, at: .root, in: state)
        }
    }

    @Test("Root declaration order is irrelevant and child mappings are relative")
    func relativeScopeAndOrder() throws {
        let state = try state(), descriptor = Descriptor(root: shape, rootDeclarations: roots)
        try descriptor.validateRenderer(shape, rootDeclarations: Array(roots.reversed()), at: .root, in: state)
        try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .route(.home))], at: ["home"], in: state)
        try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .route(.settings))], at: ["settings"], in: state)
        expectFailure(.rendererMismatch) {
            try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .route(.settings))], at: ["home"], in: state)
        }
    }

    @Test("Opaque root semantics compare explicit IDs and exclude visual metadata")
    func explicitSemanticIdentity() throws {
        let root: [Root] = [.init(meaning: .declarationID("account-root.v1"))]
        let descriptor = Descriptor(root: .stack, rootDeclarations: root)
        // A separately reconstructed renderer may use new/localized labels or
        // closures while retaining the same semantic declaration identifier.
        try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .declarationID("account-root.v1"))], at: .root, in: RouterState<R>.rootStack)
        expectFailure(.rendererMismatch) {
            try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .declarationID("account-root.v2"))], at: .root, in: RouterState<R>.rootStack)
        }
        expectFailure(.rendererMismatch) {
            try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .route(.home))], at: .root, in: RouterState<R>.rootStack)
        }
    }

    @Test("Root declarations require unique, nonempty, explicitly rendered paths")
    func rootTargets() throws {
        let state = try state()
        expectFailure(.duplicateDeclaration) {
            try Descriptor(root: shape, rootDeclarations: [roots[0], roots[0]]).validate(state)
        }
        for declaration in [
            Root(path: ["missing"], meaning: .route(.home)),
            Root(path: ["home", "missing"], meaning: .route(.home)),
            Root(path: [""], meaning: .route(.home)),
            Root(meaning: .declarationID("")),
        ] {
            expectFailure(.invalidDeclaration) {
                try Descriptor(root: shape, rootDeclarations: [declaration]).validate(state)
            }
        }
        let preserved = RouterHostShape.tabs(branches: [.init("home", shape: .stack)], extras: .preserveDormant)
        expectFailure(.invalidDeclaration) {
            try Descriptor(root: preserved, rootDeclarations: [.init(path: ["settings"], meaning: .route(.settings))]).validate(state)
        }
    }

    @Test("Nested root mappings survive exact presentation and window scopes")
    func catalogRoots() throws {
        let presentationID = UUID(), windowID = UUID()
        let child = try state().root
        let entry = RouterHostCatalogEntry<R>("tabs", shape: shape, rootDeclarations: roots)
        let catalog = RouterHostCatalog<R>(entries: [entry], declaration: { _ in "tabs" })
        let descriptor = Descriptor(root: .stack, presentations: catalog, windows: catalog)
        let state = try RouterState<R>(
            root: .stack(presentation: .init(id: presentationID, route: .compose, style: .sheet, node: child)),
            windows: [.init(id: windowID, route: .window, node: child)]
        )
        try descriptor.validateRenderer(.stack, at: .root, in: state)
        for path in [RouterScopePath.root.appendingPresentation(presentationID), .window(windowID)] {
            try descriptor.validateRenderer(shape, rootDeclarations: roots, at: path, in: state)
            try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .route(.home))], at: path.appending("home"), in: state)
            expectFailure(.rendererMismatch) { try descriptor.validateRenderer(shape, at: path, in: state) }
        }
    }

    @Test("Unused catalog root mappings still reject malformed declarations")
    func unusedCatalogRoots() {
        let entry = RouterHostCatalogEntry<R>("unused", shape: .stack, rootDeclarations: [.init(path: ["missing"], meaning: .route(.home))])
        let descriptor = Descriptor(root: .stack, windows: .init(entries: [entry], declaration: { _ in nil }))
        expectFailure(.invalidDeclaration) { try descriptor.validate(.rootStack) }
    }

    @Test("Root declaration metadata and counts are cumulative across unused catalogs")
    func cumulativeRootResources() throws {
        let entry = RouterHostCatalogEntry<R>("x", shape: .stack, rootDeclarations: [.init(meaning: .declarationID("éé"))])
        let catalog = RouterHostCatalog<R>(entries: [entry], declaration: { _ in "x" })
        let descriptor = Descriptor(root: .stack, presentations: catalog, windows: catalog)
        expectFailure(.resourceLimit) {
            try descriptor.validate(.rootStack, resourceBudget: .init(snapshot: try .init(maximumPayloadBytes: 9)))
        }
        try descriptor.validate(.rootStack, resourceBudget: .init(snapshot: try .init(maximumPayloadBytes: 10)))
        expectFailure(.resourceLimit) {
            try descriptor.validate(.rootStack, resourceBudget: .init(snapshot: try .init(maximumNodes: 4)))
        }
        try descriptor.validate(.rootStack, resourceBudget: .init(snapshot: try .init(maximumNodes: 5)))
    }

    @Test("Oversized root paths and semantic IDs reject before any route callback")
    func admissionBeforeCallbacks() throws {
        let route = Probe(value: "private-root")
        let root = RouterHostRootDeclaration<Probe>(meaning: .route(route))
        let descriptor = RouterHostDescriptor<Probe>(root: .stack, rootDeclarations: [root], windows: .init(
            entries: [.init("window", shape: .stack)], declaration: { _ in Probe.calls.withLock { $0.resolver += 1 }; return "window" }
        ))
        let state = try RouterState<Probe>(root: .stack(), windows: [.init(route: route)])
        let oversized: [RouterHostRootDeclaration<Probe>] = [
            root, .init(path: [.init(String(repeating: "s", count: 100))], meaning: .declarationID("secret")),
        ]
        Probe.reset()
        expectFailure(.resourceLimit) {
            try descriptor.validateRenderer(.stack, rootDeclarations: oversized, at: .root, in: state, resourceBudget: .init(snapshot: try .init(maximumPayloadBytes: 20)))
        }
        #expect(Probe.counts == Counts())
        let unused = RouterHostDescriptor<Probe>(root: .stack, rootDeclarations: [root], windows: .init(
            entries: [.init("window", shape: .stack, rootDeclarations: [.init(meaning: .declarationID(String(repeating: "s", count: 100)))])],
            declaration: { _ in Probe.calls.withLock { $0.resolver += 1 }; return "window" }
        ))
        expectFailure(.resourceLimit) {
            try unused.validateRenderer(.stack, rootDeclarations: [root], at: .root, in: state, resourceBudget: .init(snapshot: try .init(maximumPayloadBytes: 20)))
        }
        #expect(Probe.counts == Counts())
    }

    @Test("Deep and excessive root mappings are rejected before comparing routes")
    func depthAndCountAdmission() throws {
        let root = RouterHostRootDeclaration<Probe>(meaning: .route(.init(value: "private-root")))
        let descriptor = RouterHostDescriptor<Probe>(root: .stack, rootDeclarations: [root], presentations: .none)
        Probe.reset()
        expectFailure(.resourceLimit) {
            try descriptor.validateRenderer(.stack, rootDeclarations: [.init(path: Array(repeating: "branch", count: 10), meaning: root.meaning)], at: .root, in: RouterState<Probe>.rootStack, resourceBudget: .init(snapshot: try .init(maximumGraphDepth: 3)))
        }
        expectFailure(.resourceLimit) {
            try descriptor.validateRenderer(.stack, rootDeclarations: Array(repeating: root, count: 10), at: .root, in: RouterState<Probe>.rootStack, resourceBudget: .init(snapshot: try .init(maximumNodes: 3)))
        }
        #expect(Probe.counts == Counts())
    }

    @Test("Invalid candidate structure rejects before root equality")
    func invalidCandidateBeforeEquality() throws {
        let root = RouterHostRootDeclaration<Probe>(meaning: .route(.init(value: "private-root")))
        let tabs = RouterHostShape.tabs(branches: [.init("home", shape: .stack)], extras: .reject)
        let descriptor = RouterHostDescriptor<Probe>(root: tabs, rootDeclarations: [root], presentations: .none)
        var container = try RouterContainerState<Probe>(style: .tabs, selection: "home", branches: [.init(id: "home")])
        container.selection = "absent"
        Probe.reset()
        expectFailure(.invalidState) {
            try descriptor.validateRenderer(tabs, rootDeclarations: [root], at: .root, in: RouterStateDraft(root: .container(container)))
        }
        #expect(Probe.counts == Counts())
    }

    @Test("Exact route equality never hashes or describes payloads and mismatch stays redacted")
    func routeCallbackBoundary() throws {
        let root = RouterHostRootDeclaration<Probe>(meaning: .route(.init(value: "private-root")))
        let descriptor = RouterHostDescriptor<Probe>(root: .stack, rootDeclarations: [root])
        Probe.reset()
        try descriptor.validateRenderer(.stack, rootDeclarations: [root], at: .root, in: RouterState<Probe>.rootStack)
        #expect(Probe.counts == Counts(equality: 1))
        Probe.reset()
        do {
            try descriptor.validateRenderer(.stack, rootDeclarations: [.init(meaning: .route(.init(value: "private-other")))], at: .root, in: RouterState<Probe>.rootStack)
            Issue.record("Expected a semantic root mismatch")
        } catch let failure {
            #expect(failure.code == .rendererMismatch)
            #expect(!String(describing: failure).contains("private"))
            #expect(!String(reflecting: failure).contains("private"))
        }
        #expect(Probe.counts == Counts(equality: 1))
    }

    private struct Counts: Equatable { var equality = 0; var hash = 0; var description = 0; var resolver = 0 }
    private struct Probe: Route, CustomStringConvertible, CustomDebugStringConvertible {
        let value: String
        static let calls = Mutex(Counts())
        static var counts: Counts { calls.withLock { $0 } }
        static func reset() { calls.withLock { $0 = Counts() } }
        static func == (lhs: Self, rhs: Self) -> Bool { calls.withLock { $0.equality += 1 }; return lhs.value == rhs.value }
        func hash(into hasher: inout Hasher) { Self.calls.withLock { $0.hash += 1 }; hasher.combine(value) }
        var description: String { Self.calls.withLock { $0.description += 1 }; return value }
        var debugDescription: String { description }
    }
}
