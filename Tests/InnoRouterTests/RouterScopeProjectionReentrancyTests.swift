import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Scope projection reentrancy", .timeLimit(.minutes(1)))
@MainActor
struct RouterScopeProjectionReentrancyTests {
    private enum R: String, Route, Codable { case home, detail, replacement }

    @MainActor
    private final class Capture {
        weak var store: RouterStore<R>?
        var old: RouterScope<R>?
        var acquired: [RouterScope<R>] = []
        var terminalCount = 0
    }

    private func state() throws -> RouterState<R> {
        try RouterState(root: .container(RouterContainerState(
            style: .tabs, selection: "left", branches: [
                .init(id: "left", node: .stack(path: [.home], presentation: .init(
                    route: .detail, style: .sheet, node: .stack(path: [.detail])
                ))),
                .init(id: "right", node: .stack(path: [.home])),
            ]
        )))
    }

    private func expectExpired(_ scope: RouterScope<R>) {
        let reader = RouterStateReader(scope: scope)
        #expect(scope.state == nil)
        #expect(scope.node == nil)
        #expect(reader.node == nil)
        #expect(reader.path.isEmpty)
        #expect(reader.presentation == nil)
        #expect(!reader.canGoBack)
        #expect(!reader.canDismissPresentation)
    }

    @Test("Equal replacement exposes expired projections before synchronous terminal listeners reacquire", arguments: [false, true])
    func equalReplacementTerminalReacquisition(useRestore: Bool) async throws {
        let capture = Capture()
        let store = RouterStore(initialState: try state(), configuration: .init(onEvent: { event in
            guard case .unchanged = event, let store = capture.store, let old = capture.old else { return }
            capture.terminalCount += 1
            expectExpired(old)
            capture.acquired.append(store.scope(at: ["left"]))
        }))
        capture.store = store
        let old = store.scope(at: ["left"])
        capture.old = old
        let sibling = store.scope(at: ["right"])
        let initial = store.state
        let observer = store.addSynchronousEventObserver { event in
            guard case .unchanged = event else { return }
            expectExpired(old)
            #expect(store.scope(at: ["left"]) === capture.acquired.last)
        }
        defer { store.removeSynchronousEventObserver(observer) }
        let outcome: RouterOutcome<R>
        if useRestore {
            let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
            outcome = try await store.restore(from: codec.encode(initial), using: codec)
        } else {
            outcome = await store.replaceSubtree(at: ["left"], with: try #require(old.node))
        }
        guard case .unchanged = outcome else { Issue.record("Expected an equal-state replacement"); return }
        #expect(capture.terminalCount == 1)
        #expect(store.revision == 0)
        #expect(store.state == initial)
        expectExpired(old)
        let current = try #require(capture.acquired.last)
        #expect(current !== old)
        #expect(current.node == initial.node(at: ["left"]))
        if !useRestore { #expect(sibling === store.scope(at: ["right"])) }
        guard case .rejected(_, _, _, .mutation(.expiredScope(["left"]))) = await old.perform(.push(.detail)) else {
            Issue.record("Old authority must remain rejected"); return
        }
        guard case .applied = await current.perform(.dismissPresentation) else {
            Issue.record("Fresh authority must remain usable"); return
        }
        expectExpired(old)
    }

    @Test("State and revision observation can reacquire before changed replacement refresh", arguments: [false, true])
    func changedReplacementObservationReacquisition(observeRevision: Bool) async throws {
        let store = RouterStore(initialState: try state())
        let old = store.scope(at: ["left"])
        let sibling = store.scope(at: ["right"])
        let capture = Capture()
        withObservationTracking {
            if observeRevision { _ = store.revision } else { _ = store.state }
        } onChange: {
            MainActor.assumeIsolated { capture.acquired.append(store.scope(at: ["left"])) }
        }
        guard case .applied = await store.replaceSubtree(at: ["left"], with: .stack(path: [.replacement])) else {
            Issue.record("Expected changed replacement"); return
        }
        #expect(capture.acquired.count == 1)
        expectExpired(old)
        let current = try #require(capture.acquired.first)
        #expect(current !== old)
        #expect(current === store.scope(at: ["left"]))
        #expect(current.node == .stack(path: [.replacement]))
        #expect(sibling === store.scope(at: ["right"]))
        #expect(store.revision == 1)
    }

    @Test("Cross-scope lifetime observers cannot strand either retired projection")
    func lifetimeObservationReacquisition() async throws {
        let store = RouterStore(initialState: try state())
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        let capture = Capture()
        // Observation runs on willSet. Whichever lifetime slot changes second
        // can reacquire the first one's new incarnation before refresh begins.
        withObservationTracking { _ = store.scope(at: ["left"]) } onChange: {
            MainActor.assumeIsolated { capture.acquired.append(store.scope(at: ["right"])) }
        }
        withObservationTracking { _ = store.scope(at: ["right"]) } onChange: {
            MainActor.assumeIsolated { capture.acquired.append(store.scope(at: ["left"])) }
        }
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        guard case .unchanged = try await store.restore(from: codec.encode(store.state), using: codec) else {
            Issue.record("Expected equal restore"); return
        }
        #expect(capture.acquired.count == 2)
        expectExpired(left)
        expectExpired(right)
        #expect(store.scope(at: ["left"]) !== left)
        #expect(store.scope(at: ["right"]) !== right)
        #expect(store.revision == 0)
    }

    @Test("Same-path lifetime observation acquires the canonical new authority")
    func samePathLifetimeObservationReacquisition() async throws {
        let store = RouterStore(initialState: try state())
        let old = store.scope(at: ["left"])
        let capture = Capture()
        withObservationTracking { _ = store.scope(at: ["left"]) } onChange: {
            MainActor.assumeIsolated { capture.acquired.append(store.scope(at: ["left"])) }
        }
        guard case .unchanged = await store.replaceSubtree(at: ["left"], with: try #require(old.node)) else {
            Issue.record("Expected equal replacement"); return
        }
        let current = try #require(capture.acquired.first)
        #expect(current !== old)
        #expect(current === store.scope(at: ["left"]))
        #expect(current.state == store.state)
        expectExpired(old)
        guard case .applied = await current.perform(.dismissPresentation) else {
            Issue.record("A scope acquired inside lifetime observation must own the new authority"); return
        }
    }

    @Test("System replacement refreshes retained and reacquired scopes at most once", arguments: [false, true])
    func systemReconciliationIsDeduplicated(changesState: Bool) async throws {
        let store = RouterStore(initialState: try state())
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        let capture = Capture()
        if changesState {
            withObservationTracking { _ = store.revision } onChange: {
                MainActor.assumeIsolated { capture.acquired.append(store.scope(at: ["left"])) }
            }
        }
        let node: RouterNode<R> = changesState ? .stack(path: [.replacement]) : try #require(left.node)
        _ = await store.replaceSubtree(at: ["left"], with: node, context: .init(source: .system))
        expectExpired(left)
        #expect(left.reconciliationRevision == 1)
        #expect(right.reconciliationRevision == 1)
        if let acquired = capture.acquired.first { #expect(acquired.reconciliationRevision == 1) }
        #expect(store.revision == (changesState ? 1 : 0))
    }

    @Test("Ordinary equal apply and rejected replacement retain current projections", arguments: [false, true])
    func nonretiringControls(rejectReplacement: Bool) async throws {
        let capture = Capture()
        let store = RouterStore(initialState: try state(), configuration: .init(
            policies: rejectReplacement ? [.init(name: "deny") { _ in .reject("denied") }] : [],
            onEvent: { event in
                switch event {
                case .unchanged, .rejected:
                    guard let store = capture.store else { return }
                    capture.acquired.append(store.scope(at: ["left"]))
                default: break
                }
            }
        ))
        capture.store = store
        let old = store.scope(at: ["left"])
        let initial = store.state
        if rejectReplacement {
            guard case .rejected = await store.replaceSubtree(at: ["left"], with: try #require(old.node)) else {
                Issue.record("Expected policy rejection"); return
            }
        } else {
            guard case .unchanged = await store.perform(.apply(.init(state: initial))) else {
                Issue.record("Expected ordinary no-op"); return
            }
        }
        #expect(capture.acquired.first === old)
        #expect(old.state == initial)
        #expect(old.node == initial.node(at: ["left"]))
        #expect(store.revision == 0)
    }
}
