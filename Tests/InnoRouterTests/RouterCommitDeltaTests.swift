import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum DeltaRoute: String, Route, Codable {
    case first, second, sheet, window
}

/// A commit that keeps the graph's shape skips the lifetime rebuild and
/// refreshes only the scopes whose subtree changed. These tests pin both the
/// classification and the behaviour that depends on it.
@Suite("Commit delta", .serialized)
@MainActor
struct RouterCommitDeltaTests {
    private typealias R = DeltaRoute
    private typealias Store = RouterStore<R>

    private func tabs(
        selection: RouterScopeID = "a",
        a: RouterNode<R> = .stack(),
        b: RouterNode<R> = .stack(),
        badges: [RouterScopeID: Int] = [:]
    ) throws -> RouterState<R> {
        try RouterState(root: .container(.init(
            style: .tabs, selection: selection,
            branches: [.init(id: "a", node: a), .init(id: "b", node: b)], badges: badges
        )))
    }

    private func invalidates(reading read: () -> Void, when mutate: () async -> Void) async -> Bool {
        let fired = TestCell(false)
        withObservationTracking(read) { fired.value = true }
        await mutate()
        return fired.value
    }

    @Test("Equal states change nothing and keep the structure")
    func equalStates() throws {
        let state = try tabs(a: .stack(path: [.first]))
        #expect(Store.subtreesChanged(from: state, to: state) == [])
    }

    @Test("A value change names the changed scope and its ancestors only")
    func valueChanges() throws {
        let before = try tabs()
        #expect(Store.subtreesChanged(from: before, to: try tabs(a: .stack(path: [.first])))
            == [.root, RouterScopePath.root.appending("a")])
        #expect(Store.subtreesChanged(from: before, to: try tabs(selection: "b")) == [.root])
        #expect(Store.subtreesChanged(from: before, to: try tabs(badges: ["b": 2])) == [.root])
        #expect(Store.subtreesChanged(
            from: before, to: try tabs(a: .stack(path: [.first]), b: .stack(path: [.second]))
        ) == [.root, RouterScopePath.root.appending("a"), RouterScopePath.root.appending("b")])
    }

    @Test("A change below a retained presentation descends into its scope")
    func presentationChild() throws {
        let id = UUID()
        func state(childPath: [R]) throws -> RouterState<R> {
            try tabs(a: .stack(RouterStackState(
                path: [.first],
                presentation: .init(id: id, route: .sheet, style: .sheet, node: .stack(path: childPath))
            )))
        }
        let tab = RouterScopePath.root.appending("a")
        #expect(Store.subtreesChanged(from: try state(childPath: []), to: try state(childPath: [.second]))
            == [.root, tab, tab.appendingPresentation(id)])
    }

    @Test("Any change of shape or scenes is left to the general path")
    func shapeChanges() throws {
        let before = try tabs()
        let sheet = RouterPresentation<R>(route: .sheet, style: .sheet)
        let presented = try tabs(a: .stack(RouterStackState(path: [], presentation: sheet)))
        // A presentation appeared, disappeared, or was replaced by another.
        #expect(Store.subtreesChanged(from: before, to: presented) == nil)
        #expect(Store.subtreesChanged(from: presented, to: before) == nil)
        let other = try tabs(a: .stack(RouterStackState(
            path: [], presentation: .init(route: .sheet, style: .sheet)
        )))
        #expect(Store.subtreesChanged(from: presented, to: other) == nil)
        // A branch was renamed, added, or the node kind changed.
        let renamed = try RouterState<R>(root: .container(.init(
            style: .tabs, selection: "a", branches: [.init(id: "a"), .init(id: "c")]
        )))
        #expect(Store.subtreesChanged(from: before, to: renamed) == nil)
        #expect(Store.subtreesChanged(from: before, to: .rootStack(path: [.first])) == nil)
        // A window opened.
        var withWindow = RouterStateDraft(before)
        withWindow.windows = [RouterWindow(route: .window)]
        #expect(Store.subtreesChanged(from: before, to: try withWindow.build(resourceBudget: .provisional)) == nil)
    }

    @Test("A shape-preserving commit keeps every lifetime token")
    func tokensSurviveValueCommits() async throws {
        let store = try Store(initialState: try tabs())
        let scope = store.scope(at: ["b"])
        let tokens = store.scopeLifetimes.mapValues { $0.token }

        for action: RouterAction<R> in [.scoped("a", .push(.first)), .select("b"), .setBadge(1, for: "a")] {
            guard case .applied = await store.perform(action) else {
                Issue.record("\(action) did not commit, so the token check would prove nothing")
                return
            }
        }

        #expect(store.scopeLifetimes.mapValues { $0.token } == tokens)
        #expect(scope.matchesCurrentLifetime)
        guard case .container(let container) = store.state.root else {
            Issue.record("Expected the tab container")
            return
        }
        #expect(container.selection == "b")
        #expect(container.badges["a"] == 1)
        #expect(store.state.node(at: ["a"]) == .stack(path: [.first]))
    }

    @Test("Presenting and dismissing still rebuild lifetimes and retire the child scope")
    func shapeCommitsRebuild() async throws {
        let store = try Store(initialState: try tabs())
        let before = Set(store.scopeLifetimes.keys)

        _ = await store.perform(.scoped("a", .present(.init(route: .sheet, style: .sheet))))
        let presented = try #require(store.scope(at: ["a"]).observedPresentation)
        let childPath = RouterScopePath.root.appending("a").appendingPresentation(presented.id)
        #expect(store.scopeLifetimes[childPath] != nil)
        let child = store.scope(at: childPath)
        #expect(child.matchesCurrentLifetime)

        // A value change inside the child keeps it alive.
        _ = await child.perform(.push(.second))
        #expect(child.matchesCurrentLifetime)
        #expect(child.observedPath == [.second])

        _ = await store.perform(.scoped("a", .dismissPresentation))
        #expect(Set(store.scopeLifetimes.keys) == before)
        #expect(!child.matchesCurrentLifetime)
        #expect(child.node == nil)
    }

    @Test("A commit in a presented child publishes to the child and its ancestors only")
    func childCommitPublishesUpTheChain() async throws {
        let store = try Store(initialState: try tabs())
        _ = await store.perform(.scoped("a", .present(.init(route: .sheet, style: .sheet))))
        let presented = try #require(store.scope(at: ["a"]).observedPresentation)
        let tab = store.scope(at: ["a"])
        let sibling = store.scope(at: ["b"])
        let child = store.scope(at: RouterScopePath.root.appending("a").appendingPresentation(presented.id))
        let push: () async -> Void = { _ = await child.perform(.push(.second)) }

        #expect(await invalidates(reading: { _ = child.observedPath }, when: push))
        #expect(await invalidates(reading: { _ = tab.node }) { _ = await child.perform(.push(.first)) })
        #expect(await invalidates(reading: { _ = sibling.node; _ = sibling.observedPath }) {
            _ = await child.perform(.pop(count: 1))
        } == false)
        #expect(child.observedPath == [.second])
        #expect(tab.observedPresentation?.node == .stack(path: [.second]))
        #expect(sibling.node == store.state.node(at: ["b"]))
    }

    @Test("Opening a window reaches every scope's window projection")
    func windowChangeReachesAllScopes() async throws {
        let store = try Store(initialState: try tabs())
        let sibling = store.scope(at: ["b"])
        #expect(sibling.observedWindows.isEmpty)

        #expect(await invalidates(reading: { _ = sibling.observedWindows }) {
            _ = await store.perform(.openWindow(RouterWindow(route: .window)))
        })
        #expect(sibling.observedWindows.map(\.route) == [.window])
    }

    @Test("A never-refreshed scope at a missing path is still brought up to date")
    func neverRefreshedGhostScope() async throws {
        var draft = RouterStateDraft<R>(root: .stack())
        draft.windows = [RouterWindow(route: .window)]
        let store = try Store(initialState: try draft.build(resourceBudget: .provisional))
        // No node exists here, so this scope never holds a lifetime.
        let ghost = store.scope(at: ["ghost"])

        _ = await store.perform(.push(.first))

        #expect(ghost.observedWindows.isEmpty)
        #expect(ghost.node == nil)
    }

    @Test("A same-shaped ownership replacement expires scopes it did not change")
    func sameShapedReplacementExpiresUntouchedScopes() async throws {
        let store = try Store(initialState: try tabs())
        let untouched = store.scope(at: ["b"])
        #expect(untouched.matchesCurrentLifetime)

        let replacement = try tabs(a: .stack(path: [.first]))
        guard case .applied = await store.replaceSubtree(with: replacement.root) else {
            Issue.record("The replacement did not apply")
            return
        }
        #expect(!untouched.matchesCurrentLifetime)
        #expect(untouched.node == nil)
        #expect(untouched.state == nil)
        #expect(store.scope(at: ["b"]).node == .stack(path: []))
    }

    @Test("Skipped work never differs from doing all of it")
    func fastPathAgreesWithTheGeneralPath() async throws {
        let store = try Store(initialState: try tabs())
        let root = RouterScopePath.root
        var held = [store.scope(), store.scope(at: ["a"]), store.scope(at: ["b"]), store.scope(at: ["ghost"])]

        // After every commit, each held scope must equal a fresh projection of
        // the committed state, and both lifetime maps must equal a rebuild.
        func verify(_ step: String) {
            let state = store.state
            for scope in held {
                let expected = scope.matchesCurrentLifetime ? state.node(at: scope.path) : nil
                #expect(scope.node == expected, "\(scope.path) node after \(step)")
                if case .stack(let stack)? = expected {
                    #expect(scope.observedPath == stack.path, "\(scope.path) path after \(step)")
                    #expect(scope.observedPresentation == stack.presentation, "\(scope.path) sheet after \(step)")
                }
                if case .container(let container)? = expected {
                    #expect(scope.observedSelection == container.selection, "selection after \(step)")
                    #expect(scope.observedBadges == container.badges, "badges after \(step)")
                }
            }
            let rebuiltScopes = Store.makeScopeLifetimes(in: state, previous: store.scopeLifetimes)
            #expect(rebuiltScopes.mapValues { $0.token } == store.scopeLifetimes.mapValues { $0.token },
                    "scope lifetimes after \(step)")
            let rebuiltPresentations = Store.makePresentationLifetimes(
                in: state, scopes: store.scopeLifetimes, previous: store.presentationLifetimes
            )
            #expect(rebuiltPresentations.mapValues { $0.token } == store.presentationLifetimes.mapValues { $0.token },
                    "presentation lifetimes after \(step)")
        }

        verify("creation")
        _ = await store.perform(.scoped("a", .push(.first)))
        verify("push")
        _ = await store.perform(.select("b"))
        verify("select")
        _ = await store.perform(.setBadge(2, for: "a"))
        verify("badge")
        _ = await store.perform(.scoped("b", .present(.init(route: .sheet, style: .sheet))))
        verify("present")
        let sheet = try #require(store.scope(at: ["b"]).observedPresentation)
        held.append(store.scope(at: root.appending("b").appendingPresentation(sheet.id)))
        _ = await held[4].perform(.push(.second))
        verify("push in sheet")
        _ = await store.perform(.scoped("a", .push(.second)))
        verify("push beside sheet")
        _ = await store.perform(.scoped("b", .dismissPresentation))
        verify("dismiss")
        _ = await store.perform(.openWindow(RouterWindow(route: .window)))
        verify("open window")
        _ = await store.perform(.scoped("a", .popToRoot))
        verify("pop to root")
        _ = await store.replaceSubtree(with: try tabs(a: .stack(path: [.second])).root)
        verify("replace subtree")
        held.append(contentsOf: [store.scope(), store.scope(at: ["a"])])
        _ = await store.perform(.scoped("a", .push(.first)))
        verify("push after replacement")
    }

    @Test("A scope first read long after its subtree changed is current")
    func lateScopeIsCurrent() async throws {
        let store = try Store(initialState: try tabs())
        for _ in 0..<4 {
            _ = await store.perform(.scoped("a", .push(.first)))
            _ = await store.perform(.scoped("b", .push(.second)))
        }
        let late = store.scope(at: ["b"])
        #expect(late.observedPath == [.second, .second, .second, .second])
        _ = await store.perform(.scoped("b", .popToRoot))
        #expect(late.observedPath.isEmpty)
        #expect(store.scope(at: ["a"]).observedPath.count == 4)
    }
}
