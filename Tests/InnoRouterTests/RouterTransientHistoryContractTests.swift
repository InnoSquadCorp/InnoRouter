import Foundation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

@Suite("Transient presentation history contracts", .timeLimit(.minutes(1)))
@MainActor
struct RouterTransientHistoryContractTests {
    private enum R: String, Route, Codable { case home, detail, scene }

    private let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func presentation() -> RouterTransientPresentation {
        .init(content: .init(title: "Delete item?", message: "This cannot be undone.", actions: [
            .init(id: "delete", label: "Delete", role: .destructive),
            .init(id: "cancel", label: "Cancel", role: .cancel),
        ]))
    }

    private func present(_ value: RouterTransientPresentation, kind: Int) -> RouterAction<R> {
        kind == 1 ? .presentAlert(value) : .presentConfirmationDialog(value)
    }

    @Test("History path changes behind alerts and dialogs fail before policy", arguments: [1, 2], 0..<3)
    func blockedHistory(kind: Int, domain: Int) async throws {
        let owner: RouterScopePath
        let initial: RouterState<R>
        switch domain {
        case 0:
            owner = .root
            initial = .rootStack(path: [.home])
        case 1:
            owner = .window(windowID)
            initial = try .init(windows: [.init(id: windowID, route: .scene, node: .stack(path: [.home]))])
        default:
            owner = .immersiveSpace("studio")
            initial = try .init(immersiveSpace: .init(id: "studio", route: .scene, node: .stack(path: [.home])))
        }
        let policyCalls = Mutex(0)
        let store = try RouterStore(initialState: initial, configuration: .init(policies: [
            .init(name: "count") { _ in policyCalls.withLock { $0 += 1 }; return .allow },
        ]))
        let history = RouterHistory(store: store)
        defer { history.stop() }
        let value = presentation()
        guard case .applied = await store.perform(.push(.detail).inScope(owner)),
              case .applied = await store.perform(present(value, kind: kind).inScope(owner)) else {
            Issue.record("Expected the path and descriptor-only presentation to commit")
            return
        }
        #expect(await history.waitUntilRecordedRevision(2))
        #expect(history.entries.count == 2)
        #expect(history.cursor == 1)
        let before = store.state
        let fakeChild = owner.appendingPresentation(value.id)
        let navigation = await store.perform(.push(.detail).inScope(fakeChild))
        #expect(navigation == .rejected(
            id: navigation.id, state: before, revision: 2,
            reason: .mutation(.presentationIdentityMismatch(scope: owner, expected: value.id, actual: value.id))
        ))
        #expect(throws: RouterHistoryFailure.activePresentation(owner)) {
            try RouterHistory<R>.merge(initial, into: before)
        }
        #expect(await history.goBack() == .unavailable(cursor: 1, reason: .activePresentation(owner)))
        #expect(store.state == before)
        #expect(store.revision == 2)
        #expect(history.cursor == 1)
        #expect(history.entries.count == 2)
        #expect(policyCalls.withLock { $0 } == 2)
    }

    @Test("An unchanged covered path retains the entire family during sibling history", arguments: [1, 2])
    func unchangedPathRetainsFamily(kind: Int) async throws {
        let initial = try RouterState<R>(root: .container(try .init(style: .tabs, selection: "covered", branches: [
            .init(id: "covered", node: .stack(path: [.home])),
            .init(id: "other", node: .stack(path: [.home])),
        ])))
        let store = try RouterStore(initialState: initial)
        let history = RouterHistory(store: store)
        defer { history.stop() }
        let value = presentation()
        let family: RouterPresentationFamily<R> = kind == 1 ? .alert(value) : .confirmationDialog(value)
        guard case .applied = await store.perform(.push(.detail).inScope("other")),
              case .applied = await store.perform(present(value, kind: kind).inScope("covered")),
              case .applied = await store.perform(.setBadge(7, for: "other")) else {
            Issue.record("Expected sibling navigation, presentation and badge commits")
            return
        }
        #expect(await history.waitUntilRecordedRevision(3))
        #expect(history.entries.count == 2)
        #expect(history.currentEntry.navigationState.node(at: ["covered"]) == .stack(path: [.home]))
        let before = store.state
        let expected = try RouterState<R>(root: .container(try .init(style: .tabs, selection: "covered", branches: [
            .init(id: "covered", node: .stack(path: [.home], presentationFamily: family)),
            .init(id: "other", node: .stack(path: [.home])),
        ], badges: ["other": 7])))
        #expect(try RouterHistory<R>.merge(initial, into: before) == expected)
        guard case .completed(let cursor, let transition) = await history.goBack(),
              case .applied(_, let actualBefore, let after, let revision) = transition else {
            Issue.record("Expected one history commit preserving the transient family")
            return
        }
        #expect(cursor == 0)
        #expect(actualBefore == before)
        #expect(after == expected)
        #expect(revision == 4)
        #expect(store.state == expected)
        #expect(store.revision == 4)
        #expect(history.cursor == 0)
        #expect(history.currentEntry.navigationState == initial)
    }

    @Test("Cross-domain presentation collisions reject before Store policy", arguments: 0..<3, 0..<3)
    func duplicateIdentityBeforePolicy(first: Int, second: Int) async throws {
        let id = UUID()
        let content = presentation().content
        func family(_ kind: Int) -> RouterPresentationFamily<R> {
            if kind == 0 { return .navigation(.init(id: id, route: .scene, style: .sheet)) }
            let value = RouterTransientPresentation(id: id, content: content)
            return kind == 1 ? .alert(value) : .confirmationDialog(value)
        }
        let initial = try RouterState<R>(windows: [
            .init(id: windowID, route: .scene, node: .stack(presentationFamily: family(first))),
        ])
        let policyCalls = Mutex(0)
        let store = try RouterStore(initialState: initial, configuration: .init(policies: [
            .init(name: "must-not-run") { _ in policyCalls.withLock { $0 += 1 }; return .allow },
        ]))
        let result = await store.perform(.enterImmersiveSpace(.init(
            id: "studio", route: .scene, node: .stack(presentationFamily: family(second))
        )))
        #expect(result == .rejected(
            id: result.id, state: initial, revision: 0,
            reason: .mutation(.invalidTargetState(.duplicatePresentation(id)))
        ))
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(policyCalls.withLock { $0 } == 0)
    }
}
