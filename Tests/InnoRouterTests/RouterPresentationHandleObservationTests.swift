import Foundation
import Observation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Presentation handle observation contracts", .timeLimit(.minutes(1)))
@MainActor
struct RouterPresentationHandleObservationTests {
    private enum R: String, Route, Codable { case home, detail }

    @MainActor
    private final class Capture {
        var handles: [RouterPresentationHandle?] = []
        var slotValues: [RouterPresentationLifetimeObservation.Value] = []
        var states: [RouterState<R>] = []
    }

    private func tabs(left: RouterNode<R>, right: RouterNode<R> = .stack()) throws -> RouterNode<R> {
        .container(try .init(style: .tabs, selection: "left", branches: [
            .init(id: "left", node: left), .init(id: "right", node: right),
        ]))
    }

    private func alert(id: UUID = UUID()) -> RouterTransientPresentation {
        .init(id: id, content: .init(title: "Question", actions: [.init(id: "choose", label: "Choose")]))
    }

    @Test("Equal navigation child-root replacement publishes fresh authority without state or owner changes", arguments: [false, true])
    func equalNavigationChildReplacement(throughScope: Bool) async throws {
        let id = UUID()
        let child = try tabs(left: .stack())
        let initial = try RouterState<R>(root: .stack(presentation: .init(
            id: id, route: .home, style: .sheet, node: child
        )))
        let store = try RouterStore(initialState: initial)
        let owner = store.scope()
        let ownerToken = try #require(store.scopeLifetimeToken(at: .root))
        let old = try #require(store.presentationHandle())
        let oldToken = try #require(store.presentationLifetimes[id]?.token)
        let capture = Capture()
        let stateChanges = Mutex(0), ownerChanges = Mutex(0)
        withObservationTracking { _ = store.state } onChange: { stateChanges.withLock { $0 += 1 } }
        withObservationTracking { _ = store.observesScopeLifetime(at: .root) } onChange: {
            ownerChanges.withLock { $0 += 1 }
        }
        withObservationTracking {
            _ = throughScope ? owner.presentationHandle() : store.presentationHandle()
        } onChange: {
            MainActor.assumeIsolated {
                capture.handles.append(throughScope ? owner.presentationHandle() : store.presentationHandle())
                if let value = store.presentationLifetimeObservations[.root]?.value {
                    capture.slotValues.append(value)
                }
            }
        }

        guard case .unchanged = await store.replaceSubtree(at: .root.appendingPresentation(id), with: child) else {
            Issue.record("An equal child replacement must not assign state"); return
        }
        #expect(capture.handles.count == 1)
        let fresh = try #require(capture.handles.first.flatMap { $0 })
        #expect(fresh != old)
        #expect(fresh == store.presentationHandle())
        #expect(fresh.id == old.id)
        // Observation is willSet: authority must come from the already-installed
        // registry even while the presentation slot still contains the old token.
        #expect(capture.slotValues == [.current(oldToken)])
        #expect(store.presentationHandlePrecondition(fresh)(store.state) == nil)
        #expect(store.scopeLifetimeToken(at: .root) == ownerToken)
        #expect(store.scope() === owner)
        #expect(stateChanges.withLock { $0 } == 0)
        #expect(ownerChanges.withLock { $0 } == 0)
        #expect(store.state == initial)
        #expect(store.revision == 0)
        guard case .applied = await store.dismissPresentation(using: fresh) else {
            Issue.record("The handle captured synchronously must dismiss the new incarnation"); return
        }
    }

    @Test("Appearance and disappearance publish from the registry before observable state changes")
    func appearanceAndDisappearance() async throws {
        let store = RouterStore<R>()
        let value = alert()
        let appearance = Capture()
        withObservationTracking { _ = store.presentationHandle() } onChange: {
            MainActor.assumeIsolated {
                appearance.handles.append(store.presentationHandle())
                appearance.states.append(store.state)
            }
        }
        guard case .applied = await store.perform(.presentAlert(value)) else {
            Issue.record("The empty owner must admit a presentation"); return
        }
        #expect(appearance.handles.count == 1)
        let fresh = try #require(appearance.handles.first.flatMap { $0 })
        #expect(fresh == store.presentationHandle())
        #expect(fresh.id == value.id)
        #expect(appearance.states == [.rootStack])

        let beforeDismissal = store.state
        let disappearance = Capture()
        withObservationTracking { _ = store.presentationHandle() } onChange: {
            MainActor.assumeIsolated {
                disappearance.handles.append(store.presentationHandle())
                disappearance.states.append(store.state)
            }
        }
        guard case .applied = await store.dismissPresentation(using: fresh) else {
            Issue.record("The current presentation must dismiss"); return
        }
        #expect(disappearance.handles.count == 1)
        #expect(disappearance.handles.allSatisfy { $0 == nil })
        #expect(disappearance.states == [beforeDismissal])
        #expect(store.presentationLifetimeObservations.count == 1)
        #expect(store.presentationHandle() == nil)
    }

    @Test("Sibling state and ownership edits do not invalidate a presentation handle", arguments: [false, true])
    func unrelatedBranchIsolation(throughScope: Bool) async throws {
        let left = RouterNode<R>.stack(presentationFamily: .alert(alert()))
        let store = try RouterStore(initialState: RouterState(root: tabs(left: left)))
        let owner = store.scope(at: ["left"])
        let original = try #require(owner.presentationHandle())
        let updates = Mutex(0)
        withObservationTracking {
            _ = throughScope ? owner.presentationHandle() : store.presentationHandle(at: ["left"])
        } onChange: { updates.withLock { $0 += 1 } }
        _ = await store.perform(.push(.detail).inScope(["right"]))
        _ = await store.perform(.pop(count: 1).inScope(["right"]))
        _ = await store.perform(.select("right"))
        _ = await store.perform(.setBadge(3, for: "left"))
        _ = await store.replaceSubtree(at: ["right"], with: .stack())
        let next = try store.state.replacingNode(.stack(path: [.home]), at: ["right"])
        _ = await store.perform(.apply(.init(state: next)))
        #expect(updates.withLock { $0 } == 0)
        #expect(owner.presentationHandle() == original)
        // Confirm the subscription remains useful after all unrelated edits.
        _ = await store.dismissPresentation(using: original)
        #expect(updates.withLock { $0 } == 1)
    }

    @Test("Edits below a navigation child root retain its owner's presentation observation")
    func nestedChildIsolation() async throws {
        let id = UUID()
        let child = try tabs(left: .stack())
        let store = try RouterStore(initialState: RouterState<R>(root: .stack(presentation: .init(
            id: id, route: .home, style: .sheet, node: child
        ))))
        let old = try #require(store.presentationHandle())
        let updates = Mutex(0)
        withObservationTracking { _ = store.presentationHandle() } onChange: { updates.withLock { $0 += 1 } }
        let descendant = RouterScopePath.root.appendingPresentation(id).appending("right")
        _ = await store.perform(.push(.detail).inScope(descendant))
        _ = await store.replaceSubtree(at: descendant, with: .stack(path: [.home]))
        #expect(updates.withLock { $0 } == 0)
        #expect(store.presentationHandle() == old)
        _ = await store.dismissPresentation(using: old)
        #expect(updates.withLock { $0 } == 1)
    }

    @Test("Invalid paths and container nodes allocate no presentation observation slots")
    func invalidLookupsAreBounded() throws {
        let store = try RouterStore(initialState: RouterState<R>(root: tabs(left: .stack())))
        for index in 0..<100 {
            #expect(store.presentationHandle(at: .root.appending(.init("missing-\(index)"))) == nil)
            #expect(store.presentationHandle(at: .window(UUID())) == nil)
            #expect(store.presentationHandle(at: .immersiveSpace("missing-\(index)")) == nil)
            #expect(store.presentationHandle(at: .root.appendingPresentation(UUID())) == nil)
            #expect(store.presentationHandle() == nil)
        }
        #expect(store.presentationLifetimeObservations.isEmpty)
        #expect(store.scopeLifetimeObservations.isEmpty)
        #expect(store.presentationHandle(at: ["left"]) == nil)
        #expect(store.presentationLifetimeObservations.count == 1)
        #expect(store.scopeLifetimeObservations.isEmpty)
    }

    @Test("Removed owners retire observation slots before callbacks, including empty owners", arguments: [false, true])
    func removedOwnerSlotsAreBounded(hasPresentation: Bool) async throws {
        let store = RouterStore<R>()
        for _ in 0..<40 {
            let id = UUID()
            let node = hasPresentation ? RouterNode<R>.stack(presentationFamily: .alert(alert())) : .stack()
            guard case .applied = await store.perform(.openWindow(.init(id: id, route: .home, node: node))) else {
                Issue.record("The temporary owner must open"); return
            }
            let path = RouterScopePath.window(id)
            _ = store.presentationHandle(at: path)
            let slot = try #require(store.presentationLifetimeObservations[path])
            #expect(store.presentationLifetimeObservations.count == 1)
            let capture = Capture()
            withObservationTracking { _ = store.presentationHandle(at: path) } onChange: {
                MainActor.assumeIsolated {
                    #expect(store.presentationLifetimeObservations[path] == nil)
                    capture.handles.append(store.presentationHandle(at: path))
                }
            }
            guard case .applied = await store.perform(.dismissWindow(id)) else {
                Issue.record("The temporary owner must close"); return
            }
            #expect(capture.handles.count == 1)
            #expect(capture.handles.allSatisfy { $0 == nil })
            #expect(slot.value == .retired)
            #expect(store.presentationLifetimeObservations.isEmpty)
            #expect(store.scopeLifetimeObservations.isEmpty)
            #expect(store.scopeLifetimes.count == 1)
        }
    }

    @Test("A stack replaced by a container retires its slot and a later stack gets a new slot")
    func ownerKindReplacementRetiresSlot() async throws {
        let store = RouterStore<R>()
        #expect(store.presentationHandle() == nil)
        let previous = try #require(store.presentationLifetimeObservations[.root])
        let updates = Mutex(0)
        withObservationTracking { _ = store.presentationHandle() } onChange: { updates.withLock { $0 += 1 } }
        let container = try tabs(left: .stack())
        _ = await store.replaceSubtree(with: container)
        #expect(updates.withLock { $0 } == 1)
        #expect(previous.value == .retired)
        #expect(store.presentationLifetimeObservations.isEmpty)
        _ = await store.replaceSubtree(with: .stack())
        #expect(store.presentationHandle() == nil)
        let current = try #require(store.presentationLifetimeObservations[.root])
        #expect(current !== previous)
        #expect(store.presentationLifetimeObservations.count == 1)
    }
}
