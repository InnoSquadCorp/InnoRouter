import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Presentation incarnation contracts", .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationIncarnationContractTests {
    private enum R: String, Route, Codable { case home, detail }

    private func family(_ kind: Int, id: UUID = UUID()) -> RouterPresentationFamily<R> {
        let transient = RouterTransientPresentation(
            id: id, content: .init(title: "Question", actions: [.init(id: "choose", label: "Choose")])
        )
        switch kind {
        case 0: return .navigation(.init(id: id, route: .home, style: .sheet))
        case 1: return .alert(transient)
        default: return .confirmationDialog(transient)
        }
    }

    private func present(_ family: RouterPresentationFamily<R>) -> RouterAction<R> {
        switch family {
        case .navigation(let value): .present(value)
        case .alert(let value): .presentAlert(value)
        case .confirmationDialog(let value): .presentConfirmationDialog(value)
        }
    }

    private func tabs(left: RouterNode<R>, right: RouterNode<R> = .stack()) throws -> RouterNode<R> {
        .container(try .init(style: .tabs, selection: "left", branches: [
            .init(id: "left", node: left), .init(id: "right", node: right),
        ]))
    }

    private func respond(
        selecting: Bool,
        using handle: RouterPresentationHandle,
        in store: RouterStore<R>
    ) async -> RouterOutcome<R> {
        if selecting { return await store.selectPresentationAction("choose", using: handle) }
        return await store.dismissPresentation(using: handle)
    }

    private func expectExpired(_ outcome: RouterOutcome<R>, handle: RouterPresentationHandle) {
        guard case .rejected(_, _, _, .mutation(.expiredPresentation(let id, let scope))) = outcome else {
            Issue.record("Expected typed expired presentation rejection"); return
        }
        #expect(id == handle.id)
        #expect(scope == handle.scope)
    }

    @Test("All committed families receive authority without giving transients a child scope", arguments: 0..<3)
    func captureAndNoFakeNode(kind: Int) async throws {
        let value = family(kind)
        let store = RouterStore<R>()
        #expect(store.presentationHandle() == nil)
        _ = await store.perform(present(value))
        let handle = try #require(store.presentationHandle())
        #expect(handle.id == value.id)
        #expect(handle.scope == .root)
        #expect(store.presentationLifetimePrecondition(id: value.id, at: .root)(store.state) == nil)
        #expect(store.scope().presentationLifetimePrecondition(id: value.id)(store.state) == nil)
        #expect(store.presentationLifetimes.count == 1)
        #expect(store.presentationWaiters.isEmpty)
        let childPath = RouterScopePath.root.appendingPresentation(value.id)
        if kind == 0 {
            #expect(store.state.node(at: childPath) == .stack())
            #expect(store.scopeLifetimeToken(at: childPath) != nil)
        } else {
            #expect(store.state.node(at: childPath) == nil)
            #expect(store.scopeLifetimeToken(at: childPath) == nil)
            #expect(store.presentationLifetimes[value.id]?.childToken == nil)
            let missing = store.scope(at: childPath)
            #expect(missing.node == nil)
            guard case .rejected(_, _, _, .mutation(.expiredScope(childPath))) = await missing.perform(.push(.detail)) else {
                Issue.record("A transient must not grant navigation authority"); return
            }
        }
        guard case .applied = await respond(selecting: kind != 0, using: handle, in: store) else {
            Issue.record("Current captured authority must apply"); return
        }
        #expect(store.state == .rootStack)
        #expect(store.presentationLifetimes.isEmpty)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.revision == 2)
    }

    @Test("Initialization registers root, branch, window and immersive families")
    func initializationDomains() throws {
        let root = family(1), window = family(2), immersive = family(0)
        let windowID = UUID()
        let state = try RouterState<R>(
            root: tabs(left: .stack(presentationFamily: root)),
            windows: [.init(id: windowID, route: .home, node: .stack(presentationFamily: window))],
            immersiveSpace: .init(id: "space", route: .home, node: .stack(presentationFamily: immersive))
        )
        let store = try RouterStore(initialState: state)
        #expect(store.presentationHandle() == nil)
        #expect(store.presentationHandle(at: ["left"])?.id == root.id)
        #expect(store.presentationHandle(at: .window(windowID))?.id == window.id)
        #expect(store.presentationHandle(at: .immersiveSpace("space"))?.id == immersive.id)
        #expect(Set(store.presentationLifetimes.keys) == [root.id, window.id, immersive.id])
    }

    @Test("Equal owner replacement retires same-ID authority in every family", arguments: 0..<3)
    func sameIDReplacement(kind: Int) async throws {
        let node = RouterNode<R>.stack(presentationFamily: family(kind))
        let store = try RouterStore(initialState: RouterState(root: node))
        let old = try #require(store.presentationHandle())
        guard case .unchanged = await store.replaceSubtree(with: node) else {
            Issue.record("Equal replacement should rotate ownership without state assignment"); return
        }
        let current = try #require(store.presentationHandle())
        #expect(current != old)
        #expect(current.id == old.id)
        expectExpired(await store.dismissPresentation(using: old), handle: old)
        if kind != 0 { expectExpired(await store.selectPresentationAction("choose", using: old), handle: old) }
        #expect(store.state.root == node)
        #expect(store.revision == 0)
        guard case .applied = await store.dismissPresentation(using: current) else {
            Issue.record("Fresh authority should dismiss the replacement"); return
        }
    }

    @Test("Removal followed by same-ID re-add never revives an old handle", arguments: 0..<3)
    func removeAndReadd(kind: Int) async throws {
        let value = family(kind)
        let store = try RouterStore(initialState: RouterState(root: .stack(presentationFamily: value)))
        let old = try #require(store.presentationHandle())
        _ = await store.perform(.dismissPresentation)
        #expect(store.presentationHandle() == nil)
        _ = await store.perform(present(value))
        let current = try #require(store.presentationHandle())
        #expect(current != old)
        expectExpired(await store.dismissPresentation(using: old), handle: old)
        #expect(store.revision == 2)
        #expect(store.presentationHandle() == current)
    }

    @Test("Exact navigation restore rotates same-ID authority without inventing transient persistence")
    func exactNavigationRestore() async throws {
        let initial = try RouterState<R>(root: .stack(presentationFamily: family(0)))
        let store = try RouterStore(initialState: initial)
        let old = try #require(store.presentationHandle())
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        guard case .unchanged = try await store.restore(from: codec.encode(initial), using: codec) else {
            Issue.record("Expected exact equal navigation restore"); return
        }
        expectExpired(await store.dismissPresentation(using: old), handle: old)
        #expect(store.presentationHandle() != old)
        #expect(store.state == initial)
        #expect(store.revision == 0)
    }

    @Test("Sibling push pop selection badge and plan edits preserve captured authority", arguments: 0..<3)
    func unrelatedEdits(kind: Int) async throws {
        let left = RouterNode<R>.stack(presentationFamily: family(kind))
        let store = try RouterStore(initialState: RouterState(root: tabs(left: left)))
        let handle = try #require(store.presentationHandle(at: ["left"]))
        _ = await store.perform(.push(.detail).inScope(["right"]))
        _ = await store.perform(.pop(count: 1).inScope(["right"]))
        _ = await store.perform(.select("right"))
        _ = await store.perform(.setBadge(2, for: "left"))
        let next = try store.state.replacingNode(.stack(path: [.home]), at: ["right"])
        _ = await store.perform(.apply(.init(state: next)))
        #expect(store.presentationHandle(at: ["left"]) == handle)
        guard case .applied = await respond(selecting: kind != 0, using: handle, in: store) else {
            Issue.record("Unrelated edits must retain captured authority"); return
        }
        #expect(store.state.node(at: ["right"]) == .stack(path: [.home]))
    }

    @Test("A child branch edit preserves outer authority while child-root replacement retires it")
    func navigationChildOwnership() async throws {
        let inner = family(1), outerID = UUID()
        let child = try tabs(left: .stack(presentationFamily: inner))
        let outer = RouterPresentation<R>(id: outerID, route: .home, style: .sheet, node: child)
        let store = try RouterStore(initialState: RouterState(root: .stack(presentation: outer)))
        let childPath = RouterScopePath.root.appendingPresentation(outerID)
        let innerPath = childPath.appending("left")
        let outerHandle = try #require(store.presentationHandle())
        let innerHandle = try #require(store.presentationHandle(at: innerPath))
        _ = await store.replaceSubtree(at: childPath.appending("right"), with: .stack(path: [.detail]))
        #expect(store.presentationHandle() == outerHandle)
        #expect(store.presentationHandle(at: innerPath) == innerHandle)
        let replacedChild = try #require(store.state.node(at: childPath))
        _ = await store.replaceSubtree(at: childPath, with: replacedChild)
        expectExpired(await store.dismissPresentation(using: outerHandle), handle: outerHandle)
        expectExpired(await store.selectPresentationAction("choose", using: innerHandle), handle: innerHandle)
        #expect(store.presentationHandle() != outerHandle)
        #expect(store.presentationHandle(at: innerPath) != innerHandle)
        #expect(store.revision == 1)
    }

    @Test("Removing a navigation owner retires every nested family")
    func ownerRemoval() async throws {
        let nested = family(2), outerID = UUID()
        let outer = RouterPresentation<R>(id: outerID, route: .home, style: .sheet, node: .stack(presentationFamily: nested))
        let store = try RouterStore(initialState: RouterState(root: .stack(presentation: outer)))
        let nestedPath = RouterScopePath.root.appendingPresentation(outerID)
        let handle = try #require(store.presentationHandle(at: nestedPath))
        #expect(store.presentationLifetimes.count == 2)
        _ = await store.perform(.dismissPresentation)
        #expect(store.presentationLifetimes.isEmpty)
        #expect(store.scopeLifetimes.count == 1)
        guard case .rejected = await store.selectPresentationAction("choose", using: handle) else {
            Issue.record("A removed owner must invalidate its child's callback"); return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 1)
    }

    @Test("An explicit missing capture remains invalid after its logical ID appears")
    func missingCapture() async throws {
        let value = family(1)
        let store = RouterStore<R>()
        let missing = store.presentationRuntimePrecondition(id: value.id, at: .root)
        let missingStoreCallback = store.presentationLifetimePrecondition(id: value.id, at: .root)
        let missingScopeCallback = store.scope().presentationLifetimePrecondition(id: value.id)
        _ = await store.perform(present(value))
        let rejection = RouterRejectionReason.mutation(.expiredPresentation(value.id, scope: .root))
        #expect(missing(store.state) == rejection)
        #expect(missingStoreCallback(store.state) == rejection)
        #expect(missingScopeCallback(store.state) == rejection)
        let current = try #require(store.presentationHandle())
        #expect(store.presentationHandlePrecondition(current)(store.state) == nil)
    }

    @Test("Identical logical state in another Store grants no captured authority", arguments: 0..<3)
    func crossStore(kind: Int) async throws {
        let state = try RouterState<R>(root: .stack(presentationFamily: family(kind)))
        let first = try RouterStore(initialState: state), second = try RouterStore(initialState: state)
        let handle = try #require(first.presentationHandle())
        expectExpired(await second.dismissPresentation(using: handle), handle: handle)
        #expect(first.state == state)
        #expect(second.state == state)
        #expect(second.revision == 0)
        guard case .applied = await first.dismissPresentation(using: handle) else {
            Issue.record("The same handle must work in its owning Store"); return
        }
    }

    @MainActor
    private final class Capture { var handles: [RouterPresentationHandle?] = [] }

    @Test("Synchronous observers capture installed new authority before observable values change", arguments: [false, true], [false, true])
    func observationReentrancy(observeState: Bool, reuseID: Bool) async throws {
        let initialFamily = family(1)
        let store = try RouterStore(initialState: RouterState(root: .stack(presentationFamily: initialFamily)))
        let old = try #require(store.presentationHandle())
        let capture = Capture()
        withObservationTracking {
            if observeState { _ = store.state } else { _ = store.scope() }
        } onChange: {
            MainActor.assumeIsolated { capture.handles.append(store.presentationHandle()) }
        }
        let replacement = reuseID ? initialFamily : family(2)
        // A path change also exercises the state willSet observer for same-ID replacement.
        let node = RouterNode<R>.stack(path: [.detail], presentationFamily: replacement)
        _ = await store.replaceSubtree(with: node)
        #expect(capture.handles.count == 1)
        let current = try #require(capture.handles.first.flatMap { $0 })
        #expect(current == store.presentationHandle())
        #expect(current != old)
        #expect(current.id == replacement.id)
        #expect(store.presentationHandlePrecondition(current)(store.state) == nil)
        guard case .applied = await store.selectPresentationAction("choose", using: current) else {
            Issue.record("A reentrant capture must own the replacement's new authority"); return
        }
        #expect(store.state.root == .stack(path: [.detail]))
    }

    @Test("Observing a handle tracks equal ownership replacement without a state assignment")
    func equalReplacementObservation() async throws {
        let node = RouterNode<R>.stack(presentationFamily: family(1))
        let store = try RouterStore(initialState: RouterState(root: node))
        let old = try #require(store.presentationHandle())
        let capture = Capture()
        withObservationTracking { _ = store.presentationHandle() } onChange: {
            MainActor.assumeIsolated { capture.handles.append(store.presentationHandle()) }
        }
        _ = await store.replaceSubtree(with: node)
        #expect(capture.handles.count == 1)
        let current = try #require(capture.handles.first.flatMap { $0 })
        #expect(current != old)
        #expect(current == store.presentationHandle())
        #expect(store.revision == 0)
    }

    @Test("An expired scope cannot recapture a replacement's current presentation", arguments: 0..<3)
    func expiredScopeLateCapture(kind: Int) async throws {
        let node = RouterNode<R>.stack(presentationFamily: family(kind))
        let store = try RouterStore(initialState: RouterState(root: node))
        let oldScope = store.scope()
        let oldHandle = try #require(store.presentationHandle())
        _ = await store.replaceSubtree(with: node)
        let lateCapture = oldScope.presentationLifetimePrecondition(id: oldHandle.id)
        #expect(lateCapture(store.state) == .mutation(.expiredScope(.root)))
        let fresh = store.scope().presentationLifetimePrecondition(id: oldHandle.id)
        #expect(fresh(store.state) == nil)
    }

    @Test("Queued callbacks cannot act on a same-ID replacement", arguments: [1, 2], [false, true])
    func queuedCallback(kind: Int, selecting: Bool) async throws {
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        let (queued, enqueue) = AsyncStream<Void>.makeStream()
        defer { enter.finish(); resume.finish(); enqueue.finish() }
        var responsePolicyCalls = 0
        var configuration = RouterStoreConfiguration<R>(policies: [
            .init(name: "hold-replacement") { transition in
                if case .apply = transition.action {
                    enter.yield(())
                    for await _ in release { break }
                } else { responsePolicyCalls += 1 }
                return .allow
            },
        ])
        configuration.runtimeDependencies.didQueueRequest = { _ in enqueue.yield(()) }
        let node = RouterNode<R>.stack(presentationFamily: family(kind))
        let store = try RouterStore(initialState: RouterState(root: node), configuration: configuration)
        let old = try #require(store.presentationHandle())
        let replacement = Task { @MainActor in await store.replaceSubtree(with: node) }
        var entry = entered.makeAsyncIterator()
        _ = await entry.next()
        let callback = Task { @MainActor in await respond(selecting: selecting, using: old, in: store) }
        var queue = queued.makeAsyncIterator()
        _ = await queue.next()
        resume.yield(())
        _ = await replacement.value
        expectExpired(await callback.value, handle: old)
        #expect(responsePolicyCalls == 0)
        #expect(store.state.root == node)
        #expect(store.revision == 0)
        #expect(store.presentationHandle() != old)
    }

    @Test("Rebased deferrals retain captured authority across same-ID replacement", arguments: [1, 2], [false, true])
    func deferredCallback(kind: Int, selecting: Bool) async throws {
        let deferral = RouterDeferralID()
        let node = RouterNode<R>.stack(presentationFamily: family(kind))
        let store = try RouterStore(initialState: RouterState(root: node), configuration: .init(policies: [
            .init(name: "defer-response") { transition in
                if transition.context.resumedDeferral == nil {
                    switch transition.action {
                    case .dismissPresentation, .selectPresentationAction: return .deferRequest(deferral)
                    default: break
                    }
                }
                return .allow
            },
        ]))
        let old = try #require(store.presentationHandle())
        guard case .deferred = await respond(selecting: selecting, using: old, in: store) else {
            Issue.record("Expected response deferral"); return
        }
        #expect(store.presentationHandle() == old)
        _ = await store.replaceSubtree(with: node)
        expectExpired(await store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState), handle: old)
        #expect(store.state.root == node)
        #expect(store.revision == 0)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("Unchanged captured authority can resume a deferred descriptor response", arguments: [false, true])
    func deferredCurrentControl(selecting: Bool) async throws {
        let deferral = RouterDeferralID()
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(presentationFamily: family(1))), configuration: .init(policies: [
            .init(name: "defer-once") { transition in
                transition.context.resumedDeferral == nil ? .deferRequest(deferral) : .allow
            },
        ]))
        let handle = try #require(store.presentationHandle())
        guard case .deferred = await respond(selecting: selecting, using: handle, in: store) else {
            Issue.record("Expected response deferral"); return
        }
        guard case .applied = await store.resumeDeferred(deferral) else {
            Issue.record("An unchanged current handle must survive deferral"); return
        }
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
        #expect(store.revision == 1)
    }

    @Test("Owning Store raw actions intentionally address current authority", arguments: [1, 2])
    func rawActionCurrentAuthority(kind: Int) async throws {
        let value = family(kind)
        let node = RouterNode<R>.stack(presentationFamily: value)
        let store = try RouterStore(initialState: RouterState(root: node))
        let old = try #require(store.presentationHandle())
        _ = await store.replaceSubtree(with: node)
        expectExpired(await store.selectPresentationAction("choose", using: old), handle: old)
        guard case .applied = await store.perform(.selectPresentationAction(presentationID: value.id, actionID: "choose")) else {
            Issue.record("The owning Store may deliberately target its current descriptor"); return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Unknown descriptor action rejects before policies without consuming authority")
    func unknownAction() async throws {
        var calls = 0
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(presentationFamily: family(1))), configuration: .init(policies: [
            .init(name: "count") { _ in calls += 1; return .allow },
        ]))
        let handle = try #require(store.presentationHandle())
        guard case .rejected(_, _, _, .mutation(.unknownPresentationAction(.root))) = await store.selectPresentationAction("missing", using: handle) else {
            Issue.record("Unknown selection must be a typed structural rejection"); return
        }
        #expect(calls == 0)
        #expect(store.presentationHandle() == handle)
        #expect(store.revision == 0)
        _ = await store.selectPresentationAction("choose", using: handle)
        #expect(calls == 1)
        #expect(store.state == .rootStack)
    }
}
