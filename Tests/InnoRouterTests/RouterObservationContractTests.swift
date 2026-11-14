import Foundation
import Observation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum ObservedRoute: String, Route, Codable {
    case first, second, sheet
}

/// `RouterStore` writes its one observable accessor by hand, and a scope skips
/// publication when its subtree did not change. Both are performance changes
/// that must leave Observation behavior exactly as the macro produced it.
@Suite("Observation contract", .serialized)
@MainActor
struct RouterObservationContractTests {
    private typealias R = ObservedRoute

    /// Registers `read` with Observation and reports whether `mutate`
    /// invalidated it.
    private func invalidates(
        reading read: () -> Void,
        when mutate: () async -> Void
    ) async -> Bool {
        let fired = TestCell(false)
        withObservationTracking(read) { fired.value = true }
        await mutate()
        return fired.value
    }

    private func makeTabStore() throws -> RouterStore<R> {
        try RouterStore(initialState: try RouterState(root: .container(.init(
            style: .tabs, selection: "a", branches: [.init(id: "a"), .init(id: "b")]
        ))))
    }

    @Test("Each committed-value read is invalidated by a commit")
    func storeReadsAreObserved() async throws {
        let store = RouterStore<R>()

        #expect(await invalidates(reading: { _ = store.state }) {
            _ = await store.perform(.push(.first))
        })
        #expect(await invalidates(reading: { _ = store.revision }) {
            _ = await store.perform(.push(.second))
        })
        #expect(await invalidates(reading: { _ = store.hostDescriptor }) {
            _ = await store.perform(.pop(count: 1))
        })
        #expect(store.state.root == .stack(path: [.first]))
        #expect(store.revision == 3)
    }

    @Test("A request that commits nothing invalidates no store observer")
    func nonCommitsAreNotObserved() async throws {
        let store = RouterStore<R>()
        _ = await store.perform(.present(.init(route: .sheet, style: .sheet)))

        // Rejected: a stack cannot be pushed under its sheet.
        #expect(await invalidates(reading: { _ = store.state }) {
            guard case .rejected = await store.perform(.push(.first)) else {
                Issue.record("Expected a rejection")
                return
            }
        } == false)
        // Unchanged: the route is not on an idle store's stack.
        let idle = RouterStore<R>()
        #expect(await invalidates(reading: { _ = idle.revision }) {
            guard case .unchanged = await idle.perform(.popTo(.second)) else {
                Issue.record("Expected an unchanged outcome")
                return
            }
        } == false)
    }

    @Test("A commit invalidates the scopes it changed and no sibling")
    func siblingScopeIsNotInvalidated() async throws {
        let store = try makeTabStore()
        let root = store.scope()
        let changed = store.scope(at: ["a"])
        let sibling = store.scope(at: ["b"])
        let push: () async -> Void = { _ = await store.perform(.scoped("a", .push(.first))) }

        #expect(await invalidates(reading: { _ = changed.observedPath }, when: push))
        #expect(await invalidates(reading: { _ = root.node }) {
            _ = await store.perform(.scoped("a", .push(.second)))
        })
        #expect(await invalidates(reading: {
            _ = sibling.node
            _ = sibling.observedPath
            _ = sibling.observedPresentation
            _ = sibling.observedSelection
        }) {
            _ = await store.perform(.scoped("a", .pop(count: 1)))
        } == false)
        #expect(changed.observedPath == [.first])
        #expect(sibling.observedPath.isEmpty)
    }

    @Test("A scope skipped across many commits still publishes its own next change")
    func skippedScopeStaysCurrent() async throws {
        let store = try makeTabStore()
        let sibling = store.scope(at: ["b"])
        for _ in 0..<8 {
            _ = await store.perform(.scoped("a", .push(.first)))
            _ = await store.perform(.scoped("a", .pop(count: 1)))
        }
        #expect(sibling.observedPath.isEmpty)

        #expect(await invalidates(reading: { _ = sibling.observedPath }) {
            _ = await store.perform(.scoped("b", .push(.second)))
        })
        #expect(sibling.observedPath == [.second])
        #expect(sibling.node == store.state.node(at: ["b"]))
    }

    @Test("Every observed property tracks the committed subtree through a sequence")
    func observedPropertiesFollowState() async throws {
        let store = try makeTabStore()
        let root = store.scope()
        let tab = store.scope(at: ["a"])

        func verify(_ step: String) {
            guard case .container(let container) = store.state.root,
                  case .stack(let stack) = store.state.node(at: ["a"]) else {
                Issue.record("Unexpected shape after \(step)")
                return
            }
            #expect(root.node == store.state.root, "root node after \(step)")
            #expect(root.observedSelection == container.selection, "selection after \(step)")
            #expect(root.observedBadges == container.badges, "badges after \(step)")
            #expect(root.observedContainerStyle == .tabs, "style after \(step)")
            #expect(tab.node == .stack(stack), "tab node after \(step)")
            #expect(tab.observedPath == stack.path, "path after \(step)")
            #expect(tab.observedPresentation == stack.presentation, "presentation after \(step)")
            #expect(tab.observedPresentationFamily == stack.presentationFamily, "family after \(step)")
            #expect(tab.observedContainerStyle == nil, "tab style after \(step)")
        }

        verify("creation")
        _ = await store.perform(.scoped("a", .push(.first)))
        verify("push")
        _ = await store.perform(.scoped("a", .present(.init(route: .sheet, style: .sheet))))
        verify("present")
        _ = await store.perform(.setBadge(4, for: "b"))
        verify("badge")
        _ = await store.perform(.scoped("a", .dismissPresentation))
        verify("dismiss")
        _ = await store.perform(.select("b"))
        verify("select")
        _ = await store.perform(.scoped("a", .popToRoot))
        verify("pop to root")
    }

    @Test("A scope whose subtree was replaced away stops publishing stale values")
    func expiredScopeClearsItsProjection() async throws {
        let store = try makeTabStore()
        let tab = store.scope(at: ["a"])
        _ = await store.perform(.scoped("a", .push(.first)))
        #expect(tab.observedPath == [.first])

        // Replacing the whole root with a stack retires the tab scope.
        let replaced = await store.replaceSubtree(with: .stack(path: [.second]))
        guard case .applied = replaced else {
            Issue.record("The root replacement did not apply: \(replaced)")
            return
        }
        #expect(tab.node == nil)
        #expect(tab.observedPath.isEmpty)
        #expect(tab.state == nil)
    }
}
