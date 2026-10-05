import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

@Suite("Admitted presentation declaration lookup")
struct RouterHostPresentationDeclarationTests {
    private enum R: Route { case compose }
    private final class Calls: Sendable {
        let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func next() -> Int { value.withLock { $0 += 1; return $0 } }
    }

    @Test("One accessor lookup resolves each presentation exactly once")
    func oneResolution() throws {
        let calls = Calls(), id = UUID()
        let descriptor = RouterHostDescriptor<R>(root: .stack, presentations: .init(entries: [
            .init("first", shape: .stack, rootDeclarations: [.init(meaning: .declarationID("first-root"))]),
            .init("second", shape: .stack),
        ], declaration: { _ in calls.next() == 1 ? "first" : "second" }))
        let state = try RouterState<R>(root: .stack(presentation: .init(id: id, route: .compose, style: .sheet)))
        let entry = try descriptor.presentationDeclaration(at: .root.appendingPresentation(id), in: state)
        #expect(entry.id == "first")
        #expect(entry.shape == .stack)
        #expect(entry.rootDeclarations.count == 1)
        #expect(calls.count == 1)
    }

    @Test("Nested presentation lookup does not invoke a second selection resolver")
    func nestedResolution() throws {
        let calls = Calls(), outer = UUID(), inner = UUID()
        let descriptor = RouterHostDescriptor<R>(root: .stack, presentations: .init(
            entries: [.init("stack", shape: .stack)], declaration: { _ in _ = calls.next(); return "stack" }
        ))
        let nested = RouterNode<R>.stack(presentation: .init(id: inner, route: .compose, style: .sheet))
        let state = try RouterState<R>(root: .stack(presentation: .init(id: outer, route: .compose, style: .sheet, node: nested)))
        let entry = try descriptor.presentationDeclaration(at: .root.appendingPresentation(outer).appendingPresentation(inner), in: state)
        #expect(entry.id == "stack")
        #expect(calls.count == 2)
    }

    @Test("Unknown and mismatched presentation declarations fail before yielding a renderer")
    func rejectedDeclarations() throws {
        let id = UUID(), path = RouterScopePath.root.appendingPresentation(id)
        let state = try RouterState<R>(root: .stack(presentation: .init(id: id, route: .compose, style: .sheet)))
        let unknown = RouterHostDescriptor<R>(root: .stack, presentations: .none)
        #expect(throws: RouterHostValidationFailure.self) { _ = try unknown.presentationDeclaration(at: path, in: state) }
        do { _ = try unknown.presentationDeclaration(at: path, in: state) }
        catch let failure { #expect(failure.code == .unknownDeclaration) }
        let mismatch = RouterHostDescriptor<R>(root: .stack, presentations: .init(
            entries: [.init("tabs", shape: .tabs(branches: [.init("one", shape: .stack)], extras: .reject))], declaration: { _ in "tabs" }
        ))
        do { _ = try mismatch.presentationDeclaration(at: path, in: state); Issue.record("Expected shape rejection") }
        catch let failure { #expect(failure.code == .kindMismatch) }
    }

    @Test("Dormant presentations and nonpresentation scopes are not native renderer roots")
    func dormantAndNonpresentation() throws {
        let id = UUID()
        let shape = RouterHostShape.tabs(branches: [.init("home", shape: .stack)], extras: .preserveDormant)
        let descriptor = RouterHostDescriptor<R>(root: shape)
        let state = try RouterState<R>(root: .container(.init(style: .tabs, selection: "home", branches: [
            .init(id: "home"), .init(id: "legacy", node: .stack(presentation: .init(id: id, route: .compose, style: .sheet))),
        ])))
        for path in [RouterScopePath.root, ["home"], RouterScopePath(["legacy"]).appendingPresentation(id)] {
            do { _ = try descriptor.presentationDeclaration(at: path, in: state); Issue.record("Expected unavailable rendered presentation") }
            catch let failure { #expect(failure.code == .missingScope) }
        }
    }
}
